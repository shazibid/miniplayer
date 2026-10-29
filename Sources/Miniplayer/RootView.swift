import AppKit
import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var skinStore: SkinStore
    var onMinimize: () -> Void

    /// Window origin and mouse position (both in screen coordinates) when
    /// the current window drag began; `nil` between drags.
    @State private var windowDragStart: (origin: NSPoint, mouse: NSPoint)?

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
        // `window.isMovableByWindowBackground` (set in main.swift) only kicks
        // in when no view claims the mouse-down, and `.contextMenu` below
        // claims every click on this shape to watch for right-clicks — so on
        // its own the window can't be dragged at all. This drags it
        // explicitly instead; `.simultaneousGesture` keeps it from stealing
        // clicks from the buttons inside.
        //
        // Deltas come from `NSEvent.mouseLocation` (screen coordinates), not
        // `value.translation`: the gesture measures in the view's own space,
        // which moves along with the window, so its translation would chase
        // its own tail and jitter.
        .simultaneousGesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    guard let window = widgetWindow else { return }
                    let mouse = NSEvent.mouseLocation
                    let start = windowDragStart ?? (window.frame.origin, mouse)
                    windowDragStart = start
                    window.setFrameOrigin(NSPoint(
                        x: start.origin.x + mouse.x - start.mouse.x,
                        y: start.origin.y + mouse.y - start.mouse.y
                    ))
                }
                .onEnded { _ in
                    windowDragStart = nil
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
