import XCTest
@testable import WallpaperMachine

@MainActor
final class SequoiaAerialLockPlaybackTests: XCTestCase {
  func testLockedBridgeHoldsDisplayOnceAndReleasesOnUnlock() async {
    var locked = false
    var starts = 0
    var holds = 0
    var releases = 0
    let playback = SequoiaAerialLockPlayback(
      isLocked: { locked }, bridgeIsSelected: { true },
      holdDisplay: {
        holds += 1
        return { releases += 1 }
      }, startScreenSaver: { starts += 1; return true })

    await playback.refresh()
    XCTAssertEqual(holds, 0)
    locked = true
    await playback.refresh()
    await playback.refresh()
    XCTAssertEqual(holds, 1)
    XCTAssertEqual(starts, 0)
    locked = false
    await playback.refresh()
    XCTAssertEqual(releases, 1)
    playback.stop()
    XCTAssertEqual(releases, 1)
  }

  func testNoBridgeDoesNotKeepDisplayAwakeOrLaunchScreenSaver() async {
    var starts = 0
    var releases = 0
    let playback = SequoiaAerialLockPlayback(
      isLocked: { true }, bridgeIsSelected: { false },
      holdDisplay: { { releases += 1 } },
      startScreenSaver: { starts += 1; return true })
    await playback.refresh()
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(releases, 1)
  }

  func testSelectionStaysHeldUntilReleased() async {
    var releases = 0
    let playback = SequoiaAerialLockPlayback(
      isLocked: { true }, bridgeIsSelected: { true },
      holdDisplay: { { releases += 1 } }, startScreenSaver: { true })
    await playback.refresh()
    XCTAssertEqual(releases, 0)
    playback.stop()
    XCTAssertEqual(releases, 1)
  }

  func testFailedPowerAssertionDoesNotLaunchScreenSaver() async {
    var starts = 0
    let playback = SequoiaAerialLockPlayback(
      isLocked: { true }, bridgeIsSelected: { true }, holdDisplay: { nil },
      startScreenSaver: { starts += 1; return true })
    await playback.refresh()
    XCTAssertEqual(starts, 0)
  }

  func testOnlyMatchingInstalledAerialIsEligible() throws {
    let id = UUID().uuidString
    let manifest = try JSONSerialization.data(withJSONObject: [
      "version": 1, "asset_id": id, "installed_sha256": String(repeating: "a", count: 64)
    ])
    func index(_ assetID: String) throws -> Data {
      let configuration = try PropertyListSerialization.data(
        fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
      return try PropertyListSerialization.data(fromPropertyList: [
        "Idle": ["Content": ["Choices": [[
          "Provider": "com.apple.wallpaper.choice.aerials", "Configuration": configuration
        ]]]]
      ], format: .binary, options: 0)
    }
    XCTAssertTrue(SequoiaAerialLockPlayback.bridgeIsSelected(manifest: manifest, index: try index(id)))
    XCTAssertFalse(SequoiaAerialLockPlayback.bridgeIsSelected(manifest: manifest, index: try index(UUID().uuidString)))
    XCTAssertFalse(SequoiaAerialLockPlayback.bridgeIsSelected(manifest: Data(), index: try index(id)))
    XCTAssertFalse(SequoiaAerialLockPlayback.bridgeIsSelected(manifest: manifest, index: Data()))
  }

  func testDesktopAerialCannotEnableAnotherScreenSaver() throws {
    let id = UUID().uuidString
    let manifest = try JSONSerialization.data(withJSONObject: [
      "version": 1, "asset_id": id, "installed_sha256": String(repeating: "a", count: 64)
    ])
    let configuration = try PropertyListSerialization.data(
      fromPropertyList: ["assetID": id], format: .binary, options: 0)
    let aerial: [String: Any] = ["Content": ["Choices": [[
      "Provider": "com.apple.wallpaper.choice.aerials", "Configuration": configuration
    ]]]]
    let other: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image"]]]]
    for index in [
      ["SystemDefault": ["Desktop": aerial, "Idle": other]],
      ["SystemDefault": ["Desktop": aerial]],
      ["SystemDefault": ["Idle": aerial], "Displays": ["another": ["Idle": other]]],
    ] as [[String: Any]] {
      let data = try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
      XCTAssertFalse(SequoiaAerialLockPlayback.bridgeIsSelected(manifest: manifest, index: data))
    }
  }

  func testRestoringBridgeReleasesLockedDisplay() async {
    var selected = true
    var releases = 0
    let playback = SequoiaAerialLockPlayback(
      isLocked: { true }, bridgeIsSelected: { selected },
      holdDisplay: { { releases += 1 } }, startScreenSaver: { true })
    await playback.refresh()
    selected = false
    await playback.refresh()
    XCTAssertEqual(releases, 1)
  }

  func testUnlockWhileValidatingCannotStartPlaybackLater() async {
    var locked = true
    var starts = 0
    var releases = 0
    var completion: CheckedContinuation<Bool, Never>?
    let validating = expectation(description: "validation started")
    let playback = SequoiaAerialLockPlayback(
      isLocked: { locked }, bridgeIsSelected: {
        await withCheckedContinuation {
          completion = $0
          validating.fulfill()
        }
      }, holdDisplay: { { releases += 1 } }, startScreenSaver: { starts += 1; return true })
    let pending = Task { await playback.refresh() }
    await fulfillment(of: [validating], timeout: 1)
    locked = false
    await playback.refresh()
    completion?.resume(returning: true)
    await pending.value
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(releases, 1)
  }

  func testQueuedRefreshAfterStopCannotRestartPlayback() async {
    var actions = 0
    let playback = SequoiaAerialLockPlayback(
      isLocked: { true }, bridgeIsSelected: { true },
      holdDisplay: { actions += 1; return {} },
      startScreenSaver: { actions += 1; return true })
    playback.stop()
    await playback.refresh()
    XCTAssertEqual(actions, 0)
  }

}
