#if DEBUG
import Foundation

/// Deterministic stand-in for Spotify/Music.app. Used two ways:
/// - Directly by unit tests, configured via its mutable static fields.
/// - By the shipped debug binary when launched with `MINIPLAYER_UI_TEST=1`
///   (see `main.swift`), so the XCUITest smoke suite can exercise real UI
///   states without a live Spotify/Music session.
///
/// The whole file is `#if DEBUG`-gated — it never compiles into the release
/// binary `Packaging/build-app.sh` produces.
enum FakeMediaAppController: MediaAppController {
    nonisolated(unsafe) static var isRunningValue = true
    nonisolated(unsafe) static var stateValue: PlayerState = .playing
    nonisolated(unsafe) static var trackValue: Track? = Track(
        name: "Test Song",
        artist: "Test Artist",
        album: "Test Album",
        artwork: nil,
        duration: 180
    )
    nonisolated(unsafe) static var positionValue: TimeInterval = 30
    nonisolated(unsafe) static var supportsQueue = true
    nonisolated(unsafe) static var queueResult: QueueFetchResult = .tracks([])
    /// Returned one per `queue(matching:)` call, in order, before falling
    /// back to `queueResult` — for simulating a result that changes between
    /// retries.
    nonisolated(unsafe) static var queueResultSequence: [QueueFetchResult] = []

    static func isRunning() -> Bool { isRunningValue }
    static func currentTrack() -> Track? { trackValue }
    static func playerState() -> PlayerState { stateValue }
    static func playbackPosition() -> TimeInterval { positionValue }
    static func playPause() { stateValue = (stateValue == .playing) ? .paused : .playing }
    static func next() {}
    static func previous() {}
    static func queue(matching localTrack: Track?) async -> QueueFetchResult {
        queueResultSequence.isEmpty ? queueResult : queueResultSequence.removeFirst()
    }

    /// Restores known defaults — call from `setUp`/launch so tests don't
    /// leak state into each other via these shared statics.
    static func reset() {
        isRunningValue = true
        stateValue = .playing
        trackValue = Track(name: "Test Song", artist: "Test Artist", album: "Test Album", artwork: nil, duration: 180)
        positionValue = 30
        supportsQueue = true
        queueResult = .tracks([])
        queueResultSequence = []
    }
}
#endif
