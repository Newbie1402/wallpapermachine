import AppKit
import Foundation

/// Opens the opt-in Sequoia Aerial bridge in Terminal so `sudo` can ask for the user's password
/// in a real terminal. The Python helper backs up the original Apple video before replacing it.
@MainActor
enum SequoiaAerialBridgeLauncher {
  static func apply(videoAt videoURL: URL, bundle: Bundle = .main) throws {
    try openTerminal(arguments: ["apply", videoURL.path], bundle: bundle)
  }

  static func restore(bundle: Bundle = .main) throws {
    try openTerminal(arguments: ["restore"], bundle: bundle)
  }

  static func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func commandText(arguments: [String], helperURL: URL) -> String {
    let command = ([helperURL.path] + arguments).map(shellQuoted).joined(separator: " ")
    let startScreenSaver = arguments.first == "apply"
      ? "if [[ $result -eq 0 ]]; then\n  open -a '/System/Library/CoreServices/ScreenSaverEngine.app'\nfi"
      : ""
    return """
      #!/bin/zsh
      python3 \(command)
      result=$?
      \(startScreenSaver)
      echo
      echo "Press Return to close this Terminal window."
      read -r answer
      exit $result
      """
  }

  private static func openTerminal(arguments: [String], bundle: Bundle) throws {
    guard let helperURL = bundle.url(forResource: "sequoia_aerial_bridge", withExtension: "py") else {
      throw WallpaperActionError(message: L("The Sequoia Aerial helper is missing from this app build."))
    }

    let commandURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WallpaperMachine-Aerial-\(UUID().uuidString).command")
    try commandText(arguments: arguments, helperURL: helperURL)
      .write(to: commandURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: commandURL.path)

    guard NSWorkspace.shared.open(commandURL) else {
      try? FileManager.default.removeItem(at: commandURL)
      throw WallpaperActionError(message: L("Could not open Terminal to run the Sequoia Aerial helper."))
    }
  }
}
