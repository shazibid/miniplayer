import AppKit
import Combine
import Foundation

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var state: PlayerState = .stopped
    /// Elapsed seconds into `track`, refreshed on the same poll cycle.
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var artworkImage: NSImage?
    @Published private(set) var isSourceRunning = false
    @Published private(set) var queue: [QueueTrack] = []
    @Published private(set) var isLoadingQueue = false
    /// True when the queue couldn't be shown because Spotify's account-wide
    /// active device isn't this Mac — distinct from an empty `queue`, which
    /// means "verified, and there's genuinely nothing upcoming."
    @Published private(set) var isQueueOnOtherDevice = false

    /// Whether the active app can enumerate upcoming tracks right now (see
    /// `MediaAppController.supportsQueue`) — false for Spotify until the user
    /// connects their account.
    var queueSupported: Bool { activeController?.supportsQueue ?? false }

    var duration: TimeInterval { track?.duration ?? 0 }

    /// Shared "Nothing playing" fallback text for skins with room for the
    /// full copy (Pill, CD, Vinyl). IPodView's screen is tighter and uses its
    /// own shorter strings instead.
    var nowPlayingTitle: String {
        guard isSourceRunning else { return "Nothing playing" }
        return track?.name ?? "Nothing playing"
    }

    var nowPlayingSubtitle: String {
        guard isSourceRunning else { return "Open Spotify or Music to get started" }
        return track?.artist ?? " "
    }

    private nonisolated(unsafe) static var controllers: [MediaAppController.Type] = [SpotifyController.self, AppleMusicController.self]

    #if DEBUG
    /// Test-only seam: swaps in fake controller(s) so unit tests and the
    /// XCUITest smoke suite (via `MINIPLAYER_UI_TEST=1`, see `main.swift`)
    /// can drive deterministic playback state without a real Spotify/Music
    /// session. Only reachable in debug builds — never compiled into the
    /// release binary `Packaging/build-app.sh` produces.
    static func useControllers(_ overrides: [MediaAppController.Type]) {
        controllers = overrides
    }
    #endif

    private var timer: Timer?
    private var activeController: MediaAppController.Type?
    private var lastArtworkKey: String?
    private var isQueueVisible = false
    private var lastQueueTrackKey: String?
    /// Bumped on every `fetchQueue()` so a slow, superseded fetch (e.g. from
    /// two quick skips) can't land after a newer one and overwrite it.
    private var queueFetchGeneration = 0

    /// How long to wait before re-asking when a queue fetch reports another
    /// device as active. Right after a skip, this Mac's client (read via
    /// AppleScript) already has the new track while Spotify's Web API still
    /// reports the old one for a second or two — which looks exactly like
    /// another device driving playback. Only a mismatch that survives these
    /// retries is treated as real. Internal so tests can shorten it.
    var queueMismatchRetryDelays: [Duration] = [.seconds(1), .seconds(2)]

    func startPolling() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .userInitiated) { [weak self] in
            let snapshot = Self.poll()
            await self?.apply(snapshot)
        }
    }

    /// Flips instantly so the button and the disc's spin animation update in
    /// the same frame, instead of waiting on the AppleScript round-trip.
    func togglePlayPause() {
        state = (state == .playing) ? .paused : .playing
        guard let controller = activeController else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            controller.playPause()
            let snapshot = Self.poll()
            await self?.apply(snapshot)
        }
    }

    func skipNext() {
        guard let controller = activeController else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            controller.next()
            let snapshot = Self.poll()
            await self?.apply(snapshot)
        }
    }

    func skipPrevious() {
        guard let controller = activeController else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            controller.previous()
            let snapshot = Self.poll()
            await self?.apply(snapshot)
        }
    }

    /// Fetched on demand (when the queue screen opens) and again whenever the
    /// current track changes while it's still open — a plain one-shot fetch
    /// otherwise goes stale the moment playback advances or the user skips.
    func fetchQueue() {
        guard let controller = activeController, controller.supportsQueue else {
            queue = []
            isQueueOnOtherDevice = false
            return
        }
        isLoadingQueue = true
        queueFetchGeneration += 1
        let generation = queueFetchGeneration
        let localTrack = track
        let retryDelays = queueMismatchRetryDelays
        Task.detached(priority: .userInitiated) { [weak self] in
            var result = await controller.queue(matching: localTrack)
            for delay in retryDelays {
                guard case .otherDeviceActive = result else { break }
                try? await Task.sleep(for: delay)
                guard await self?.queueFetchGeneration == generation else { return }
                result = await controller.queue(matching: localTrack)
            }
            await MainActor.run {
                guard self?.queueFetchGeneration == generation else { return }
                switch result {
                case .tracks(let tracks):
                    self?.queue = tracks
                    self?.isQueueOnOtherDevice = false
                case .otherDeviceActive:
                    self?.queue = []
                    self?.isQueueOnOtherDevice = true
                }
                self?.isLoadingQueue = false
            }
        }
    }

    /// Called by the queue screen when it's shown/hidden so `apply` knows
    /// whether it's worth re-fetching on track changes.
    func setQueueVisible(_ visible: Bool) {
        isQueueVisible = visible
        if visible {
            lastQueueTrackKey = track.map { "\($0.name)|\($0.artist)" }
            fetchQueue()
        }
    }

    /// Whether the user has connected a Spotify account — gates the
    /// "Connect"/"Disconnect" menu item's label.
    var isSpotifyConnected: Bool { SpotifyTokenStore.hasRefreshToken() }

    /// Opens the system browser for the PKCE login flow. Refreshes right
    /// after so `queueSupported`/`isSpotifyConnected` reflect the new state
    /// without waiting on the next poll tick.
    func connectSpotify() {
        Task {
            do {
                try await SpotifyAuthManager.shared.login()
                refresh()
            } catch SpotifyAuthManager.AuthError.userDenied {
                // User declined on Spotify's own consent screen — their call, not an error.
            } catch LoopbackCallbackServer.ServerError.timedOut {
                Self.showSpotifyConnectAlert(
                    "Couldn't connect to Spotify in time. This is often because Spotify currently "
                    + "limits this feature to a small number of approved accounts — a restriction "
                    + "Spotify imposes on small developer apps, not something this app controls. "
                    + "Apple Music isn't affected."
                )
            } catch {
                Self.showSpotifyConnectAlert("Couldn't connect to Spotify. Please try again in a moment.")
            }
        }
    }

    private static func showSpotifyConnectAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Spotify Connection Failed"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    func disconnectSpotify() {
        Task {
            await SpotifyAuthManager.shared.logout()
            refresh()
        }
    }

    /// Prefers whichever app is actively playing; if both are just open and
    /// paused, falls back to the first one (in `controllers` order). Nothing
    /// running means nothing to show.
    private nonisolated static func poll() -> (controller: MediaAppController.Type?, state: PlayerState, track: Track?, elapsed: TimeInterval) {
        let running = controllers.filter { $0.isRunning() }
        guard !running.isEmpty else { return (nil, .stopped, nil, 0) }
        let states = running.map { (app: $0, state: $0.playerState()) }
        let chosen = states.first(where: { $0.state == .playing }) ?? states[0]
        return (chosen.app, chosen.state, chosen.app.currentTrack(), chosen.app.playbackPosition())
    }

    private func apply(_ snapshot: (controller: MediaAppController.Type?, state: PlayerState, track: Track?, elapsed: TimeInterval)) {
        isSourceRunning = snapshot.controller != nil
        if activeController != nil, snapshot.controller == nil {
            queue = []
            isQueueOnOtherDevice = false
        }
        activeController = snapshot.controller
        state = snapshot.state
        track = snapshot.track
        elapsed = snapshot.elapsed
        loadArtworkIfNeeded()
        refreshQueueIfTrackChanged()
    }

    private func refreshQueueIfTrackChanged() {
        guard isQueueVisible else { return }
        let key = track.map { "\($0.name)|\($0.artist)" }
        guard key != lastQueueTrackKey else { return }
        lastQueueTrackKey = key
        fetchQueue()
    }

    private func loadArtworkIfNeeded() {
        guard let track else {
            artworkImage = nil
            lastArtworkKey = nil
            return
        }
        let key = "\(track.name)|\(track.artist)|\(track.album)"
        guard key != lastArtworkKey else { return }
        lastArtworkKey = key

        switch track.artwork {
        case .url(let urlString):
            guard let url = URL(string: urlString) else { artworkImage = nil; return }
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
                await MainActor.run { self.artworkImage = image }
            }
        case .data(let data):
            artworkImage = NSImage(data: data)
        case nil:
            artworkImage = nil
        }
    }
}
