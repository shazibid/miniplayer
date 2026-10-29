import XCTest
@testable import Miniplayer

/// A second fake controller, distinct from `FakeMediaAppController`, so
/// tests can exercise `PlayerViewModel`'s multi-app selection rules (prefer
/// whichever is playing; otherwise first-in-list wins).
private enum FakeControllerB: MediaAppController {
    nonisolated(unsafe) static var isRunningValue = false
    nonisolated(unsafe) static var stateValue: PlayerState = .paused
    nonisolated(unsafe) static var trackValue: Track? = Track(
        name: "B Song", artist: "B Artist", album: "B Album", artwork: nil, duration: 100
    )
    static let supportsQueue = false

    static func isRunning() -> Bool { isRunningValue }
    static func currentTrack() -> Track? { trackValue }
    static func playerState() -> PlayerState { stateValue }
    static func playbackPosition() -> TimeInterval { 0 }
    static func playPause() {}
    static func next() {}
    static func previous() {}
    static func queue(matching localTrack: Track?) async -> QueueFetchResult { .tracks([]) }

    static func reset() {
        isRunningValue = false
        stateValue = .paused
    }
}

@MainActor
final class PlayerViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        FakeMediaAppController.reset()
        FakeControllerB.reset()
    }

    func testNothingPlayingWhenNoControllerIsRunning() async {
        FakeMediaAppController.isRunningValue = false
        PlayerViewModel.useControllers([FakeMediaAppController.self])

        let viewModel = PlayerViewModel()
        viewModel.refresh()
        await waitUntil { viewModel.isSourceRunning == false }

        XCTAssertNil(viewModel.track)
        XCTAssertEqual(viewModel.state, .stopped)
        XCTAssertEqual(viewModel.nowPlayingTitle, "Nothing playing")
    }

    func testShowsRunningControllersTrack() async {
        PlayerViewModel.useControllers([FakeMediaAppController.self])

        let viewModel = PlayerViewModel()
        viewModel.refresh()
        await waitUntil { viewModel.track != nil }

        XCTAssertEqual(viewModel.track?.name, "Test Song")
        XCTAssertEqual(viewModel.nowPlayingTitle, "Test Song")
        XCTAssertEqual(viewModel.nowPlayingSubtitle, "Test Artist")
    }

    func testPlayingControllerWinsOverPausedController() async {
        FakeMediaAppController.isRunningValue = true
        FakeMediaAppController.stateValue = .paused
        FakeControllerB.isRunningValue = true
        FakeControllerB.stateValue = .playing
        // FakeMediaAppController is registered first, but B is the one
        // actually playing, so B should win.
        PlayerViewModel.useControllers([FakeMediaAppController.self, FakeControllerB.self])

        let viewModel = PlayerViewModel()
        viewModel.refresh()
        await waitUntil { viewModel.track != nil }

        XCTAssertEqual(viewModel.track?.name, "B Song")
        XCTAssertEqual(viewModel.state, .playing)
    }

    func testFirstControllerWinsWhenBothPaused() async {
        FakeMediaAppController.isRunningValue = true
        FakeMediaAppController.stateValue = .paused
        FakeControllerB.isRunningValue = true
        FakeControllerB.stateValue = .paused
        PlayerViewModel.useControllers([FakeMediaAppController.self, FakeControllerB.self])

        let viewModel = PlayerViewModel()
        viewModel.refresh()
        await waitUntil { viewModel.track != nil }

        XCTAssertEqual(viewModel.track?.name, "Test Song")
    }

    func testTogglePlayPauseFlipsStateOptimistically() async {
        FakeMediaAppController.stateValue = .playing
        PlayerViewModel.useControllers([FakeMediaAppController.self])

        let viewModel = PlayerViewModel()
        viewModel.refresh()
        await waitUntil { viewModel.track != nil }
        XCTAssertEqual(viewModel.state, .playing)

        viewModel.togglePlayPause()
        // Flips synchronously, before the fake "AppleScript" round trip.
        XCTAssertEqual(viewModel.state, .paused)
    }

    func testQueueSupportedReflectsActiveController() async {
        FakeMediaAppController.supportsQueue = true
        PlayerViewModel.useControllers([FakeMediaAppController.self])

        let viewModel = PlayerViewModel()
        viewModel.refresh()
        await waitUntil { viewModel.track != nil }

        XCTAssertTrue(viewModel.queueSupported)
    }

    func testFetchQueuePopulatesTracksFromActiveController() async {
        FakeMediaAppController.queueResult = .tracks([QueueTrack(name: "Up Next", artist: "Someone")])
        PlayerViewModel.useControllers([FakeMediaAppController.self])

        let viewModel = PlayerViewModel()
        viewModel.refresh()
        await waitUntil { viewModel.track != nil }

        viewModel.setQueueVisible(true)
        await waitUntil { !viewModel.queue.isEmpty }

        XCTAssertEqual(viewModel.queue.first?.name, "Up Next")
        XCTAssertFalse(viewModel.isQueueOnOtherDevice)
    }

    func testFetchQueueMarksOtherDeviceActive() async {
        FakeMediaAppController.queueResult = .otherDeviceActive
        PlayerViewModel.useControllers([FakeMediaAppController.self])

        let viewModel = PlayerViewModel()
        viewModel.queueMismatchRetryDelays = [.milliseconds(10)]
        viewModel.refresh()
        await waitUntil { viewModel.track != nil }

        viewModel.setQueueVisible(true)
        await waitUntil { viewModel.isQueueOnOtherDevice }

        XCTAssertTrue(viewModel.queue.isEmpty)
    }

    /// Right after a skip, Spotify's Web API briefly still reports the old
    /// track, which reads as "another device is active." A retry that then
    /// matches should show the queue, never the other-device message.
    func testTransientOtherDeviceMismatchIsRetried() async {
        FakeMediaAppController.queueResultSequence = [.otherDeviceActive]
        FakeMediaAppController.queueResult = .tracks([QueueTrack(name: "Up Next", artist: "Someone")])
        PlayerViewModel.useControllers([FakeMediaAppController.self])

        let viewModel = PlayerViewModel()
        viewModel.queueMismatchRetryDelays = [.milliseconds(10)]
        viewModel.refresh()
        await waitUntil { viewModel.track != nil }

        viewModel.setQueueVisible(true)
        await waitUntil { !viewModel.queue.isEmpty }

        XCTAssertEqual(viewModel.queue.first?.name, "Up Next")
        XCTAssertFalse(viewModel.isQueueOnOtherDevice)
    }
}
