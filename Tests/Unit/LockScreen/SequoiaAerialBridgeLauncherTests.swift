import XCTest
@testable import WallpaperMachine

final class SequoiaAerialBridgeLauncherTests: XCTestCase {
  @MainActor
  func testShellQuotingKeepsSpacesAndApostrophesInsideOneArgument() {
    XCTAssertEqual(SequoiaAerialBridgeLauncher.shellQuoted("/tmp/A user's video.mp4"), "'/tmp/A user'\\''s video.mp4'")
  }

  @MainActor
  func testApplyCommandUsesBundledHelperAndVideoPath() {
    let command = SequoiaAerialBridgeLauncher.commandText(
      arguments: ["apply", "/tmp/A user's video.mp4"],
      helperURL: URL(fileURLWithPath: "/App/Contents/Resources/sequoia_aerial_bridge.py"))

    XCTAssertTrue(command.contains("python3 '/App/Contents/Resources/sequoia_aerial_bridge.py' 'apply' '/tmp/A user'\\''s video.mp4'"))
    XCTAssertTrue(command.contains("open -a '/System/Library/CoreServices/ScreenSaverEngine.app'"))
    XCTAssertTrue(command.contains("read -r answer"))
  }

  @MainActor
  func testRestoreCommandDoesNotStartScreenSaver() {
    let command = SequoiaAerialBridgeLauncher.commandText(
      arguments: ["restore"],
      helperURL: URL(fileURLWithPath: "/App/Contents/Resources/sequoia_aerial_bridge.py"))

    XCTAssertFalse(command.contains("open -a '/System/Library/CoreServices/ScreenSaverEngine.app'"))
  }
}
