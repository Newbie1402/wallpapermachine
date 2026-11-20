#!/usr/bin/env python3
"""Tests for the reversible Sequoia Aerial video bridge."""
from __future__ import annotations

import importlib.util
import os
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("sequoia_aerial_bridge", SCRIPTS / "sequoia_aerial_bridge.py")
bridge = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(bridge)


ASSET_ID = "F439B0A7-D18C-4B14-9681-6520E6A74FE9"


def choice(provider: str, asset_id: str):
    return {
        "Provider": provider,
        "Configuration": plistlib.dumps({"assetID": asset_id}),
    }


class SelectedAerialTests(unittest.TestCase):
    def test_reads_current_linked_aerial_choice(self):
        index = {"SystemDefault": {"Type": "linked", "Linked": {
            "Content": {"Choices": [choice(bridge.AERIAL_PROVIDER, ASSET_ID)]}}}}
        self.assertEqual(bridge.selected_aerial_id(index), ASSET_ID)

    def test_reads_legacy_idle_aerial_choice(self):
        index = {"SystemDefault": {"Type": "individual", "Idle": {
            "Content": {"Choices": [choice(bridge.AERIAL_PROVIDER, ASSET_ID)]}}}}
        self.assertEqual(bridge.selected_aerial_id(index), ASSET_ID)

    def test_ignores_non_aerial_wallpapers(self):
        index = {"SystemDefault": {"Linked": {
            "Content": {"Choices": [choice("com.apple.wallpaper.choice.solid-color", ASSET_ID)]}}}}
        with self.assertRaises(bridge.BridgeError):
            bridge.selected_aerial_id(index)

    def test_rejects_different_aerials_on_multiple_displays(self):
        another = "1088217C-1410-4CF7-BDE9-8F573A4DBCD9"
        index = {"SystemDefault": {"Linked": {
            "Content": {"Choices": [choice(bridge.AERIAL_PROVIDER, ASSET_ID)]}}},
            "Displays": {"one": {"Linked": {"Content": {"Choices": [
                choice(bridge.AERIAL_PROVIDER, another)]}}}}}
        with self.assertRaises(bridge.BridgeError):
            bridge.selected_aerial_id(index)

    def test_rejects_invalid_asset_identifier(self):
        index = {"SystemDefault": {"Linked": {
            "Content": {"Choices": [choice(bridge.AERIAL_PROVIDER, "../../outside")]}}}}
        with self.assertRaises(bridge.BridgeError):
            bridge.selected_aerial_id(index)

    def test_asset_path_is_confined_to_the_customer_slot(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = bridge.asset_path(ASSET_ID, Path(temporary))
            self.assertEqual(path, Path(temporary) / f"{ASSET_ID}.mov")
            self.assertEqual(path.parent, Path(temporary))


class RestoreGuardTests(unittest.TestCase):
    def test_restore_accepts_only_the_saved_original_or_applied_content(self):
        manifest = {"original_sha256": "original", "installed_sha256": "applied"}
        self.assertTrue(bridge.restore_is_safe(manifest, "original"))
        self.assertTrue(bridge.restore_is_safe(manifest, "applied"))
        self.assertFalse(bridge.restore_is_safe(manifest, "changed-by-apple"))

    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.asset_directory = self.root / "Customer"
        self.asset_directory.mkdir()
        self.target = self.asset_directory / f"{ASSET_ID}.mov"
        self.target.write_bytes(b"original Aerial")
        self.index = self.root / "Index.plist"
        self.index.write_bytes(plistlib.dumps({"SystemDefault": {"Linked": {
            "Content": {"Choices": [choice(bridge.AERIAL_PROVIDER, ASSET_ID)]}}}}))
        self.state = self.root / "support/SequoiaAerialBridge"
        self.source = self.root / "wallpaper.mp4"
        self.source.write_bytes(b"animated WallpaperMachine video")
        self.real_owner = (self.target.stat().st_uid, self.target.stat().st_gid)

    def privileged(self, arguments, *, check=True):
        if arguments == ["-v"] or arguments[:2] == ["/usr/bin/killall", "WallpaperVideoExtension"]:
            return None
        command, *args = arguments
        if command == "/usr/bin/ditto":
            shutil.copy2(args[-2], args[-1])
        elif command == "/usr/sbin/chown":
            os.chown(args[1], *self.real_owner)
        elif command == "/bin/chmod":
            os.chmod(args[1], int(args[0], 8))
        elif command == "/bin/mv":
            os.replace(args[1], args[2])
        else:
            self.fail(f"unexpected privileged command: {arguments}")
        return None

    @staticmethod
    def convert(source, output):
        shutil.copy2(source, output)

    @staticmethod
    def repeat(source, output, _duration_seconds):
        shutil.copy2(source, output)

    def test_apply_and_restore_return_the_selected_aerial_to_exact_original_bytes(self):
        installed = bridge.apply_video(
            self.source, index_path=self.index, asset_directory=self.asset_directory,
            state_directory=self.state, privileged=self.privileged, convert=self.convert,
            repeat=self.repeat)
        self.assertEqual(installed, self.target)
        self.assertEqual(self.target.read_bytes(), self.source.read_bytes())
        self.assertTrue((self.state / f"{ASSET_ID}.original.mov").is_file())

        restored = bridge.restore_original(
            state_directory=self.state, asset_directory=self.asset_directory,
            privileged=self.privileged)
        self.assertEqual(restored, self.target)
        self.assertEqual(self.target.read_bytes(), b"original Aerial")
        self.assertFalse((self.state / bridge.MANIFEST_NAME).exists())
        self.assertFalse((self.state / f"{ASSET_ID}.original.mov").exists())

    def test_restore_refuses_to_replace_an_asset_changed_outside_the_bridge(self):
        bridge.apply_video(
            self.source, index_path=self.index, asset_directory=self.asset_directory,
            state_directory=self.state, privileged=self.privileged, convert=self.convert,
            repeat=self.repeat)
        self.target.write_bytes(b"changed by macOS")
        with self.assertRaises(bridge.BridgeError):
            bridge.restore_original(
                state_directory=self.state, asset_directory=self.asset_directory,
                privileged=self.privileged)
        self.assertTrue((self.state / f"{ASSET_ID}.original.mov").is_file())

    def test_reapply_replaces_only_its_own_video_and_keeps_the_original_backup(self):
        bridge.apply_video(
            self.source, index_path=self.index, asset_directory=self.asset_directory,
            state_directory=self.state, privileged=self.privileged, convert=self.convert,
            repeat=self.repeat)
        second_source = self.root / "second.mp4"
        second_source.write_bytes(b"second video")

        bridge.apply_video(
            second_source, index_path=self.index, asset_directory=self.asset_directory,
            state_directory=self.state, privileged=self.privileged, convert=self.convert,
            repeat=self.repeat)
        self.assertEqual(self.target.read_bytes(), second_source.read_bytes())
        self.assertEqual((self.state / f"{ASSET_ID}.original.mov").read_bytes(), b"original Aerial")

        bridge.restore_original(
            state_directory=self.state, asset_directory=self.asset_directory,
            privileged=self.privileged)
        self.assertEqual(self.target.read_bytes(), b"original Aerial")

    def test_failed_video_loop_does_not_leave_an_unrecoverable_aerial_backup(self):
        def fail_repeat(_source, _output, _duration_seconds):
            raise bridge.BridgeError("loop failed")

        with self.assertRaisesRegex(bridge.BridgeError, "loop failed"):
            bridge.apply_video(
                self.source, index_path=self.index, asset_directory=self.asset_directory,
                state_directory=self.state, privileged=self.privileged, convert=self.convert,
                repeat=fail_repeat)

        self.assertEqual(self.target.read_bytes(), b"original Aerial")
        self.assertFalse((self.state / f"{ASSET_ID}.original.mov").exists())
        self.assertFalse((self.state / bridge.MANIFEST_NAME).exists())


if __name__ == "__main__":
    unittest.main()
