import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var skinStore: SkinStore
    var onMinimize: () -> Void

    @State private var dragStartOrigin: NSPoint?

    /// This app has exactly one window, so there's no ambiguity to resolve —
    /// just find it by type rather than plumbing a reference down through
    /// the view hierarchy.
    private var widgetWindow: NSWindow? {
        NSApp.windows.first { $0 is FloatingWidgetWindow }
    }

    var body: some View {
        Group {
            switch skinStore.skin {
            case .pill: PillView(viewModel: viewModel)
            case .cd: RotatingCDView(viewModel: viewModel)
            case .vinyl: VinylView(viewModel: viewModel)
            case .ipod: IPodView(viewModel: viewModel)
            }
        }
        // No fade/scale here on purpose: each skin view already renders at
        // its own fixed size (see WidgetSkin.windowSize), and the window
        // frame animates separately in AppDelegate.resizeWindow. Leaving
        // this as `.identity` means the *only* motion you see is that
        // frame animating — the new skin's content is simply revealed or
        // clipped as the border grows/shrinks to meet it.
        .transition(.identity)
        .contentShape(Rectangle())
        // `window.isMovableByWindowBackground` (set in main.swift) is the
        // normal way to drag a borderless/titleless window, but it only
        // kicks in when AppKit sees no view handle the mouse-down at all —
        // and `.contextMenu` below installs a click/press recognizer across
        // this entire shape to detect right-clicks, which is enough to
        // defeat that heuristic for every click, not just right ones.
        // Dragging the window explicitly here, via `.simultaneousGesture`
        // (so it doesn't steal clicks from the buttons inside), sidesteps
        // the heuristic rather than depending on it.
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    // `isMovableByWindowBackground` no longer drives the
                    // window-drag itself (see above), but IPodView still
                    // flips it to `false` while the pointer is over its
                    // queue scrollbar thumb, to keep that thumb's own drag
                    // from also dragging the window underneath it. Reusing
                    // the same flag here as a gate keeps that contract
                    // intact without IPodView needing to know this gesture
                    // exists.
                    guard let window = widgetWindow, window.isMovableByWindowBackground else { return }
                    let startOrigin = dragStartOrigin ?? window.frame.origin
                    if dragStartOrigin == nil {
                        dragStartOrigin = startOrigin
                    }
                    window.setFrameOrigin(NSPoint(
                        x: startOrigin.x + value.translation.width,
                        y: startOrigin.y - value.translation.height
                    ))
                }
                .onEnded { _ in
                    dragStartOrigin = nil
                }
        )
        .contextMenu {
            ForEach(WidgetSkin.allCases) { option in
                Button {
                    withAnimation(.easeInOut(duration: WidgetSkin.transitionDuration)) {
                        skinStore.skin = option
                    }
                } label: {
                    if option == skinStore.skin {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
                .accessibilityIdentifier(AccessibilityID.skinMenuItem(option))
            }
            Divider()
            if viewModel.isSpotifyConnected {
                Button("Disconnect Spotify Account") { viewModel.disconnectSpotify() }
            } else {
                Button("Connect Spotify Account…") { viewModel.connectSpotify() }
            }
            Divider()
            Button("Minimize") { onMinimize() }
            Button("Quit") { NSApp.terminate(nil) }
                .accessibilityIdentifier(AccessibilityID.quitMenuItem)
        }
    }
}
