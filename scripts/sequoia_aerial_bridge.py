#!/usr/bin/env python3
"""Opt-in Sequoia workaround: use one WallpaperMachine video in Apple's Aerial screen saver.

This uses an undocumented macOS asset path. It is deliberately a separate command-line
tool: the user chooses when to grant administrator access, apply a video, and restore Apple’s
original Aerial. It supports one shared Aerial video at a time, not scenes or web wallpapers.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Optional

AERIAL_PROVIDER = "com.apple.wallpaper.choice.aerials"
DEFAULT_INDEX = Path.home() / "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
DEFAULT_ASSET_DIRECTORY = Path("/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS")
DEFAULT_STATE_DIRECTORY = Path.home() / "Library/Application Support/WallpaperMachine/SequoiaAerialBridge"
MANIFEST_NAME = "manifest.json"
DEFAULT_LOOP_DURATION_SECONDS = 15 * 60


class BridgeError(Exception):
    """An unsafe or unsupported Aerial replacement was refused."""


def _asset_identifier(value: object) -> str:
    try:
        return str(uuid.UUID(str(value))).upper()
    except (ValueError, AttributeError, TypeError) as error:
        raise BridgeError("The selected Aerial has an invalid asset identifier.") from error


def selected_aerial_id(index: object) -> str:
    """Find the one Aerial selected in wallpaper settings across all active displays."""
    identifiers: set[str] = set()

    def visit(value: object) -> None:
        if isinstance(value, dict):
            if value.get("Provider") == AERIAL_PROVIDER:
                configuration = value.get("Configuration")
                if not isinstance(configuration, bytes):
                    raise BridgeError("macOS did not provide the selected Aerial configuration.")
                try:
                    decoded = plistlib.loads(configuration)
                except (plistlib.InvalidFileException, ValueError, TypeError) as error:
                    raise BridgeError("macOS returned an unreadable Aerial configuration.") from error
                if not isinstance(decoded, dict) or "assetID" not in decoded:
                    raise BridgeError("The selected Aerial does not have an asset identifier.")
                identifiers.add(_asset_identifier(decoded["assetID"]))
            for child in value.values():
                visit(child)
        elif isinstance(value, (list, tuple)):
            for child in value:
                visit(child)

    visit(index)
    if not identifiers:
        raise BridgeError(
            "Choose an Apple Aerial wallpaper in System Settings and turn on “Show as Screen Saver” first."
        )
    if len(identifiers) != 1:
        raise BridgeError("Choose the same Aerial on every display before using this workaround.")
    return identifiers.pop()


def asset_path(asset_id: str, directory: Path = DEFAULT_ASSET_DIRECTORY) -> Path:
    """Return the Aerial file path, validating the ID before joining it to the system folder."""
    return directory / f"{_asset_identifier(asset_id)}.mov"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def restore_is_safe(manifest: dict, current_sha256: str) -> bool:
    """Restore only if the system file is the saved original or our last installed video."""
    return current_sha256 in {
        manifest.get("original_sha256"), manifest.get("installed_sha256"),
        manifest.get("previous_installed_sha256"),
    }


def read_index(path: Path = DEFAULT_INDEX) -> object:
    try:
        with path.open("rb") as source:
            return plistlib.load(source)
    except FileNotFoundError as error:
        raise BridgeError(f"Wallpaper settings were not found: {path}") from error
    except (plistlib.InvalidFileException, OSError) as error:
        raise BridgeError(f"Could not read wallpaper settings: {error}") from error


def _run(arguments: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(arguments, check=check, text=True)
    except FileNotFoundError as error:
        raise BridgeError(f"Required macOS tool is missing: {arguments[0]}") from error
    except subprocess.CalledProcessError as error:
        raise BridgeError(f"Command failed ({error.returncode}): {arguments[0]}") from error


def _run_privileged(arguments: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    return _run(["/usr/bin/sudo", *arguments], check=check)


def _atomic_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix=".manifest-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")
        os.chmod(name, 0o600)
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def _load_manifest(path: Path) -> Optional[dict]:
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BridgeError(f"The Aerial backup record is unreadable: {error}") from error
    if not isinstance(value, dict) or value.get("version") != 1:
        raise BridgeError("The Aerial backup record has an unsupported format.")
    value["asset_id"] = _asset_identifier(value.get("asset_id"))
    return value


def _backup_asset(target: Path, backup: Path) -> dict:
    if target.is_symlink() or not target.is_file():
        raise BridgeError("The selected Aerial asset is missing or is not a regular file.")
    info = target.stat()
    if info.st_nlink != 1:
        raise BridgeError("The selected Aerial has multiple hard links; refusing to replace it.")
    backup.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if backup.exists():
        raise BridgeError(f"An unexpected backup already exists: {backup}")
    _run(["/usr/bin/ditto", "--rsrc", "--extattr", "--acl", str(target), str(backup)])
    original_hash = sha256_file(target)
    if sha256_file(backup) != original_hash:
        backup.unlink(missing_ok=True)
        raise BridgeError("The Aerial backup did not match the original; nothing was changed.")
    os.chmod(backup, 0o600)
    return {
        "original_sha256": original_hash,
        "uid": info.st_uid,
        "gid": info.st_gid,
        "mode": stat.S_IMODE(info.st_mode),
        "backup": str(backup),
    }


def _convert_video(source: Path, output: Path) -> None:
    if source.is_symlink() or not source.is_file():
        raise BridgeError("Choose a regular video file from WallpaperMachine.")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    _run([
        "/usr/bin/avconvert", "--source", str(source), "--preset", "PresetHEVC3840x2160",
        "--output", str(output), "--replace",
    ])
    if not output.is_file() or output.stat().st_size == 0:
        raise BridgeError("macOS could not convert the source into a playable Aerial video.")


def _repeat_video(source: Path, output: Path, duration_seconds: int) -> None:
    bundled_helper = Path(__file__).with_name("repeat-aerial-video")
    if bundled_helper.is_file():
        _run([str(bundled_helper), str(source), str(output), str(duration_seconds)])
        if not output.is_file() or output.stat().st_size == 0:
            raise BridgeError("macOS could not create a repeated Aerial video.")
        return

    # Repository and direct-Xcode runs can compile the bundled source when needed.
    helper = Path(__file__).with_name("repeat_aerial_video.swift.txt")
    if not helper.is_file():
        raise BridgeError("The Aerial video repeat helper is missing from this app build.")
    with tempfile.TemporaryDirectory(prefix="wallpapermachine-aerial-") as directory:
        source_file = Path(directory) / "repeat_aerial_video.swift"
        executable = Path(directory) / "repeat-aerial-video"
        shutil.copyfile(helper, source_file)
        _run(["/usr/bin/swiftc", "-parse-as-library", str(source_file), "-o", str(executable)])
        _run([str(executable), str(source), str(output), str(duration_seconds)])
    if not output.is_file() or output.stat().st_size == 0:
        raise BridgeError("macOS could not create a repeated Aerial video.")


def _replace(target: Path, source: Path, manifest: dict, *, privileged=_run_privileged) -> None:
    temporary = target.with_name(target.name + ".wallpapermachine-tmp")
    if temporary.exists():
        raise BridgeError(f"A previous temporary file needs attention: {temporary}")
    privileged(["/usr/bin/ditto", "--rsrc", "--extattr", "--acl", str(source), str(temporary)])
    privileged(["/usr/sbin/chown", f"{manifest['uid']}:{manifest['gid']}", str(temporary)])
    privileged(["/bin/chmod", f"{manifest['mode']:o}", str(temporary)])
    privileged(["/bin/mv", "-f", str(temporary), str(target)])


def _restart_aerial(*, privileged=_run_privileged) -> None:
    # The system starts this extension again for the next Aerial presentation.
    privileged(["/usr/bin/killall", "WallpaperVideoExtension"], check=False)


def apply_video(
    source: Path,
    *,
    index_path: Path = DEFAULT_INDEX,
    asset_directory: Path = DEFAULT_ASSET_DIRECTORY,
    state_directory: Path = DEFAULT_STATE_DIRECTORY,
    privileged=_run_privileged,
    convert=_convert_video,
    repeat=_repeat_video,
    loop_duration_seconds: int = DEFAULT_LOOP_DURATION_SECONDS,
) -> Path:
    """Back up the selected Apple Aerial and install a repeated video in its slot."""
    source = source.expanduser()
    if source.is_symlink():
        raise BridgeError("Choose a regular video file from WallpaperMachine, not a symbolic link.")
    source = source.resolve()
    asset_id = selected_aerial_id(read_index(index_path))
    target = asset_path(asset_id, asset_directory)
    manifest_path = state_directory / MANIFEST_NAME
    manifest = _load_manifest(manifest_path)
    current_hash = None

    if manifest:
        if manifest["asset_id"] != asset_id or manifest.get("target") != str(target):
            raise BridgeError("Restore the replaced Aerial before selecting a different one.")
        backup = Path(str(manifest.get("backup", "")))
        if not backup.is_file() or sha256_file(backup) != manifest.get("original_sha256"):
            raise BridgeError("The saved original Aerial is missing or damaged; backup retained.")
        if not target.is_file():
            raise BridgeError("The selected Aerial file is missing; backup retained.")
        current_hash = sha256_file(target)
        if not restore_is_safe(manifest, current_hash):
            raise BridgeError("The Aerial changed outside this tool; backup retained without overwriting it.")
    else:
        backup = state_directory / f"{asset_id}.original.mov"

    state_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    converted = state_directory / ".staged-converted.mov"
    repeated = state_directory / ".staged-wallpapermachine.mov"
    if not 1 <= loop_duration_seconds <= 3600:
        raise BridgeError("The Aerial loop duration must be between 1 and 3600 seconds.")
    convert(source, converted)
    repeat(converted, repeated, loop_duration_seconds)
    installed_hash = sha256_file(repeated)
    if not manifest:
        metadata = _backup_asset(target, backup)
        manifest = {
            "version": 1,
            "asset_id": asset_id,
            "target": str(target),
            **metadata,
            "installed_sha256": None,
        }
    if manifest.get("installed_sha256") and current_hash != manifest.get("original_sha256"):
        manifest["previous_installed_sha256"] = current_hash
    manifest["installed_sha256"] = installed_hash
    _atomic_json(manifest_path, manifest)

    privileged(["-v"])
    _replace(target, repeated, manifest, privileged=privileged)
    if sha256_file(target) != installed_hash:
        raise BridgeError("The installed video did not match its staged copy; use restore immediately.")
    _restart_aerial(privileged=privileged)
    converted.unlink(missing_ok=True)
    repeated.unlink(missing_ok=True)
    manifest.pop("previous_installed_sha256", None)
    _atomic_json(manifest_path, manifest)
    return target


def restore_original(
    *,
    state_directory: Path = DEFAULT_STATE_DIRECTORY,
    asset_directory: Path = DEFAULT_ASSET_DIRECTORY,
    privileged=_run_privileged,
) -> Path:
    """Restore the original Aerial only when the target still matches our known content."""
    manifest_path = state_directory / MANIFEST_NAME
    manifest = _load_manifest(manifest_path)
    if not manifest:
        raise BridgeError("There is no WallpaperMachine Aerial replacement to restore.")
    target = asset_path(manifest["asset_id"], asset_directory)
    backup = Path(str(manifest.get("backup", "")))
    if manifest.get("target") != str(target) or not backup.is_file():
        raise BridgeError("The Aerial target or its saved original is missing; backup retained.")
    if sha256_file(backup) != manifest.get("original_sha256"):
        raise BridgeError("The saved original Aerial backup is damaged; backup retained.")
    if not target.is_file() or not restore_is_safe(manifest, sha256_file(target)):
        raise BridgeError("The Aerial changed outside this tool; backup retained without overwriting it.")

    privileged(["-v"])
    _replace(target, backup, manifest, privileged=privileged)
    if sha256_file(target) != manifest["original_sha256"]:
        raise BridgeError("The original Aerial could not be verified after restore; backup retained.")
    _restart_aerial(privileged=privileged)
    backup.unlink(missing_ok=True)
    manifest_path.unlink(missing_ok=True)
    return target


def status(
    *, index_path: Path = DEFAULT_INDEX,
    asset_directory: Path = DEFAULT_ASSET_DIRECTORY,
    state_directory: Path = DEFAULT_STATE_DIRECTORY,
) -> str:
    manifest = _load_manifest(state_directory / MANIFEST_NAME)
    selected_id = selected_aerial_id(read_index(index_path))
    if not manifest:
        return f"Aerial {selected_id} is selected; no WallpaperMachine replacement is active."
    target = asset_path(manifest["asset_id"], asset_directory)
    if manifest.get("target") != str(target):
        return "WallpaperMachine has a saved replacement for a different Aerial; restore that asset first."
    if not target.is_file():
        return "A WallpaperMachine replacement is recorded, but its Aerial file is missing."
    current = sha256_file(target)
    if current in {manifest.get("installed_sha256"), manifest.get("previous_installed_sha256")}:
        return f"WallpaperMachine video is active in Aerial {manifest['asset_id']}. Run restore to return to Apple’s video."
    if current == manifest.get("original_sha256"):
        return f"Aerial {manifest['asset_id']} has its original video; a saved backup record remains."
    return "The selected Aerial changed outside this tool; the saved backup was left untouched."


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    apply_parser = commands.add_parser("apply", help="install a video in the selected Aerial slot")
    apply_parser.add_argument("video", type=Path, help="a WallpaperMachine video that macOS can convert")
    commands.add_parser("restore", help="restore the selected Aerial from the saved backup")
    commands.add_parser("status", help="show whether the Aerial slot has been replaced")
    args = parser.parse_args(argv)
    try:
        version = platform.mac_ver()[0]
        if platform.system() != "Darwin" or not version.startswith("15."):
            raise BridgeError("This workaround is tested only on macOS Sequoia 15.x.")
        if args.command == "apply":
            target = apply_video(args.video)
            print(
                f"WallpaperMachine video installed in {target}; it repeats for at least "
                f"{DEFAULT_LOOP_DURATION_SECONDS // 60} minutes. The Aerial screen saver can now play it while you are away."
            )
            print(f"Run `{Path(sys.argv[0]).name} restore` to restore Apple’s original Aerial.")
        elif args.command == "restore":
            print(f"Restored Apple’s original Aerial at {restore_original()}.")
        else:
            print(status())
        if args.command in {"apply", "restore"}:
            _run(["/usr/bin/notifyutil", "-p", "app.wallpapermachine.sequoia-aerial.changed"])
    except BridgeError as error:
        print(f"Sequoia Aerial bridge: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
