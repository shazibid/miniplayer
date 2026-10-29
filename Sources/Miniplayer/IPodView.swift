import SwiftUI

/// Overlays a live screen and real tap targets on top of the baked-in
/// `ipod-body` artwork (a cropped device render — see Resources/) instead of
/// hand-drawing the body/wheel in SwiftUI. All the geometry below was
/// measured directly from that image's pixels, then scaled to `bodyWidth`.
struct IPodView: View {
    @ObservedObject var viewModel: PlayerViewModel

    @State private var showingQueue = false
    @State private var queueScrollMetrics = QueueScrollMetrics()
    @State private var queueScrollPosition = ScrollPosition()
    @State private var queueThumbDragStartOffset: CGFloat?
    @StateObject private var marqueeSync = MarqueeSync()

    private let bodyWidth: CGFloat = 210
    private let bodyHeight: CGFloat = 210 * (486.0 / 295.0)
    private let scale: CGFloat = 210 / 295.0

    /// Loaded via `NSImage(contentsOf:)` rather than `Image(_:bundle:)` —
    /// the latter only resolves asset-catalog entries, not loose resources
    /// like this one. Deliberately avoids `Bundle.module`: its generated
    /// accessor falls back to a hardcoded absolute build path when the
    /// resource isn't where it expects, which crashes on any machine but
    /// the one that built the binary — a real risk for a packaged .app,
    /// since codesign refuses to seal a bundle with loose content sitting
    /// outside `Contents/` (which is where `Bundle.module` looks). Looking
    /// under `Bundle.main` instead finds a plain copy placed in
    /// `Contents/Resources` (see Packaging/build-app.sh), with a
    /// source-relative fallback for `swift run`/Xcode debugging.
    private static let bodyImage: NSImage? = {
        if let url = Bundle.main.url(forResource: "ipod-body", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        let devURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ipod-body.png")
        return NSImage(contentsOf: devURL)
    }()

    /// The artwork's canvas is taller than the device itself: it reserves
    /// space at the bottom for a baked-in drop shadow. Measured from the
    /// image's pixels (using the unobstructed top half as reference, since
    /// the shadow contaminates the bottom edge), the device itself sits at
    /// x:[12, 283], y:[6, 462] out of the 295×486 canvas. Masking to that
    /// rect discards the baked shadow so the window's own native shadow
    /// (see `main.swift`) hugs the device's true silhouette instead of the
    /// full padded canvas.
    private var deviceBounds: CGRect {
        CGRect(x: 12 * scale, y: 6 * scale, width: 271 * scale, height: 456 * scale)
    }
    private var deviceCornerRadius: CGFloat { 20 * scale }

    /// The screen bezel was measured on a reference canvas where the device
    /// (i.e. `deviceBounds`, not the shadow-padded PNG) rendered at 375×628:
    /// an inner rect of 308×231 and an outer rect of 318×243 with a corner
    /// radius of 5. Only the padding between those two rects is used here —
    /// applied to the already-tuned `screenSize` — so this doesn't disturb
    /// the screen's own hand-fitted position. `deviceBounds.width / 375`
    /// converts that reference canvas into this view's own point space.
    private var screenBorderPadding: CGSize {
        let referenceScale = deviceBounds.width / 375
        return CGSize(width: 5 * referenceScale, height: 6 * referenceScale)
    }
    private var screenBorderRadius: CGFloat { 5 * deviceBounds.width / 375 }

    var body: some View {
        ZStack {
            if let bodyImage = Self.bodyImage {
                Image(nsImage: bodyImage)
                    .resizable()
                    .frame(width: bodyWidth, height: bodyHeight)
                    .mask(
                        RoundedRectangle(cornerRadius: deviceCornerRadius, style: .continuous)
                            .frame(width: deviceBounds.width, height: deviceBounds.height)
                            .position(x: deviceBounds.midX, y: deviceBounds.midY)
                    )
            }

            RoundedRectangle(cornerRadius: screenBorderRadius, style: .continuous)
                .fill(.black)
                .frame(
                    width: screenSize.width + screenBorderPadding.width * 2,
                    height: screenSize.height + screenBorderPadding.height * 2
                )
                .position(x: screenOrigin.x + screenSize.width / 2, y: screenOrigin.y + screenSize.height / 2)

            screen
                .frame(width: screenSize.width, height: screenSize.height)
                // `nowPlayingScreen`'s artwork uses `aspectRatio(.fill)`,
                // which routinely overflows `screenSize` on one axis by
                // design — this clip is load-bearing for it, unlike almost
                // everything else here. (An earlier version of this comment
                // claimed it was a no-op and removed it to let the scroll
                // thumb overflow into the bezel margin below; that broke
                // artwork cropping, visibly. The thumb overlay is attached
                // further down instead, since content added after a
                // `.clipShape` isn't itself subject to it.)
                .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
                // `.topLeading`, with the thumb positioning itself via
                // explicit offsets from there — unlike `.topTrailing`, this
                // doesn't silently assume the thumb should hug `screen`'s own
                // top edge, which is wrong now that the thumb needs to know
                // the queue ScrollView's actual (header-offset) position.
                //
                // This has to come *before* `.position()`, not after:
                // `.position()` makes the preceding view report an
                // effectively unbounded layout frame to whatever follows it
                // (that's how it can place fixed-size content at an
                // arbitrary point), so an `.overlay` chained afterward
                // resolves its alignment against that huge frame instead of
                // `screenSize` — which is exactly what was happening here
                // (confirmed by logging the actual numbers: the thumb landed
                // tens of points off from where the math said it should).
                .overlay(alignment: .topLeading) {
                    if showingQueue {
                        queueScrollThumb
                    }
                }
                .position(x: screenOrigin.x + screenSize.width / 2, y: screenOrigin.y + screenSize.height / 2)

            wheelHitTargets
        }
        .frame(width: bodyWidth, height: bodyHeight)
        // The ZStack above is laid out on the full, shadow-padded canvas so
        // every pixel-measured position (screenOrigin, wheelCenter, etc.)
        // stays valid. Shifting by -deviceBounds.origin and re-framing to
        // deviceBounds.size crops that padding away from the *window* too —
        // otherwise the window stays canvas-sized while only the artwork
        // gets clipped, leaving a dead-space margin between the visible
        // device and the window/screen edge.
        .offset(x: -deviceBounds.minX, y: -deviceBounds.minY)
        .frame(width: deviceBounds.width, height: deviceBounds.height, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.ipodRoot)
        .onChange(of: viewModel.isSourceRunning) { _, isRunning in
            if !isRunning {
                showingQueue = false
                viewModel.setQueueVisible(false)
            }
        }
    }

    // MARK: - Screen

    private var title: String {
        if !viewModel.isSourceRunning { return "Nothing Playing" }
        return viewModel.track?.name ?? "Nothing Playing"
    }

    private var subtitle: String {
        if !viewModel.isSourceRunning { return "Open Spotify or Music" }
        return viewModel.track?.artist ?? " "
    }

    private var screenOrigin: CGPoint { CGPoint(x: 32 * scale, y: 26 * scale) }
    private var screenSize: CGSize { CGSize(width: 231 * scale, height: 175 * scale) }

    private var screen: some View {
        ZStack {
            Rectangle().fill(.black)

            if showingQueue && viewModel.isSourceRunning {
                queueScreen
            } else {
                nowPlayingScreen
            }
        }
    }

    private var nowPlayingScreen: some View {
        ZStack {
            if let image = viewModel.artworkImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: screenSize.width, height: screenSize.height)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                    Text(subtitle)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.55))
            }

            if viewModel.track != nil {
                VStack {
                    Spacer()
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            MarqueeText(text: title, font: .system(size: 11, weight: .semibold), color: .white, sync: marqueeSync)
                                .accessibilityIdentifier(AccessibilityID.nowPlayingTitle)
                            MarqueeText(text: subtitle, font: .system(size: 9), color: .white.opacity(0.8), sync: marqueeSync)
                                .accessibilityIdentifier(AccessibilityID.nowPlayingSubtitle)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                }
            }
        }
    }

    // MARK: - Queue

    /// Styled after the click-wheel iPod's own list screens: a Monaco
    /// (classic bitmap-Mac heritage) header over a plain list, since there's
    /// no bundled facsimile of the original device's actual bitmap font.
    private var queueScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("UP NEXT")
                .font(.custom("Monaco", size: 11))
                .fontWeight(.bold)
                .tracking(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 5)

            Rectangle()
                .fill(.white.opacity(0.25))
                .frame(height: 1)

            if !viewModel.queueSupported {
                queueMessage("Queue not available\nfor Spotify")
            } else if viewModel.isQueueOnOtherDevice {
                queueMessage("Playing on\nanother device")
            } else if viewModel.queue.isEmpty {
                queueMessage(viewModel.isLoadingQueue ? "Loading…" : "No Upcoming Tracks")
            } else {
                // The system scroll indicator is hidden in favor of a
                // hand-drawn one (`queueScrollThumb`) pinned to the screen's
                // true trailing edge. AppKit's own indicator, at least under
                // "Show scroll bars: Always", renders its whole track
                // (thumb + groove) inset a further track-width's worth of
                // space short of the ScrollView's actual edge — a fixed
                // AppKit-level margin no combination of `.padding`,
                // `.contentMargins`, or explicit `.frame(maxWidth:)` on the
                // content could budge (confirmed by pixel-diffing screenshots
                // across all three). Drawing our own is the only way to get
                // it flush, and matches the original click-wheel iPod's own
                // list screens anyway, which never used a system scroller.
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(viewModel.queue) { track in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(track.name)
                                    .font(.custom("Monaco", size: 10))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.custom("Monaco", size: 9))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }
                // `.never`, not `.hidden` — `.hidden` still yields to the
                // user's "Show scroll bars: Always" preference (confirmed:
                // that setting is on here), which is exactly the system
                // indicator this custom thumb replaces.
                .scrollIndicators(.never)
                .contentMargins(.horizontal, 8)
                .scrollPosition($queueScrollPosition)
                .onScrollGeometryChange(for: QueueScrollMetrics.self) { geometry in
                    QueueScrollMetrics(
                        offsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height
                    )
                } action: { _, newValue in
                    queueScrollMetrics = newValue
                }
                // The thumb itself is overlaid higher up, on `screen` rather
                // than here — see the comment at that call site for why.
            }
        }
    }

    /// A thin proportional scrollbar drawn by hand (see the comment above its
    /// only call site for why) — sized and positioned from scroll geometry
    /// the same way a system indicator would be, just pinned to the screen's
    /// actual edge instead of AppKit's own inset. Draggable: since it's a
    /// hand-drawn overlay rather than a real NSScroller, dragging it doesn't
    /// move anything on its own — pushing the computed offset through
    /// `.scrollPosition` is what actually scrolls the list, mirroring what
    /// AppKit does internally for a real scroller thumb.
    private var queueScrollThumb: some View {
        let metrics = queueScrollMetrics
        let visibleFraction = metrics.contentHeight > 0
            ? min(1, metrics.containerHeight / metrics.contentHeight)
            : 1
        let thumbHeight = max(20, metrics.containerHeight * visibleFraction)
        let maxScrollableOffset = max(0, metrics.contentHeight - metrics.containerHeight)
        let scrollFraction = maxScrollableOffset > 0
            ? min(1, max(0, metrics.offsetY / maxScrollableOffset))
            : 0
        let thumbOffsetY = max(0, metrics.containerHeight - thumbHeight) * scrollFraction
        let trackRange = max(1, metrics.containerHeight - thumbHeight)
        // The ScrollView sits below the "UP NEXT" header within `screen`,
        // but the thumb is overlaid directly on `screen` (see that call
        // site), which knows nothing about the header. The VStack gives the
        // header its own ideal height and lets the ScrollView fill whatever
        // is left, so this is just that arithmetic run in reverse.
        let headerHeight = screenSize.height - metrics.containerHeight

        return Group {
            if visibleFraction < 1 {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.4))
                    .frame(width: 10, height: thumbHeight)
                    // Widens the drag/click target beyond the visible bar —
                    // 10pt is fine to look at, but fiddly to grab precisely.
                    // `alignment: .trailing` is the important part: a bare
                    // `.frame` defaults to `.center`, which would leave the
                    // 10pt bar sitting in the middle of this 20pt box —
                    // flush on neither edge (the original bug this thumb
                    // exists to fix).
                    .frame(width: 20, height: thumbHeight, alignment: .trailing)
                    .contentShape(Rectangle())
                // This is overlaid `.topLeading` on `screen` (see that call
                // site), so both axes are explicit offsets from `screen`'s
                // own top-left corner rather than alignment-derived:
                //  - x: screenSize.width lands the (right-aligned, see
                //    above) bar at the ScrollView's true trailing edge; the
                //    extra `screenBorderPadding.width` pushes it further,
                //    past that invisible inner-content boundary, to the true
                //    edge of the black bezel rect — what actually reads,
                //    visually, as "the edge of the display".
                //  - y: `headerHeight` accounts for the "UP NEXT" header
                //    sitting above the ScrollView, which the thumb would
                //    otherwise ignore and render under.
                .offset(
                    x: screenSize.width - 20 + screenBorderPadding.width,
                    y: headerHeight + thumbOffsetY
                )
                // The window is `.isMovableByWindowBackground` (no title bar
                // to drag from otherwise — see main.swift), which otherwise
                // wins the race against this gesture on mouse-down and drags
                // the whole window instead of the thumb. Turning it off
                // while the pointer is over the thumb — before any
                // mouseDown can happen — avoids that race entirely. (A
                // custom `NSViewRepresentable` overriding
                // `mouseDownCanMoveWindow` was tried first; it didn't
                // actually suppress the window drag, confirmed by testing —
                // SwiftUI's own hosting view intercepts the hit-test before
                // AppKit ever reaches an embedded subview.)
                .onHover { hovering in
                    widgetWindow?.isMovableByWindowBackground = !hovering
                }
                // If the queue shrinks enough to hide this thumb while the
                // mouse is still over it (e.g. the queue updates mid-hover),
                // `onHover`'s exit never fires — the view is just gone. Without
                // this, `isMovableByWindowBackground` would stay stuck `false`
                // and the whole window would become permanently undraggable.
                .onDisappear {
                    widgetWindow?.isMovableByWindowBackground = true
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let startOffset = queueThumbDragStartOffset ?? metrics.offsetY
                            if queueThumbDragStartOffset == nil {
                                queueThumbDragStartOffset = startOffset
                            }
                            let deltaOffset = (value.translation.height / trackRange) * maxScrollableOffset
                            let newOffset = min(max(0, startOffset + deltaOffset), maxScrollableOffset)
                            queueScrollPosition.scrollTo(y: newOffset)
                        }
                        .onEnded { _ in
                            queueThumbDragStartOffset = nil
                            widgetWindow?.isMovableByWindowBackground = true
                        }
                )
            }
        }
    }

    private struct QueueScrollMetrics: Equatable {
        var offsetY: CGFloat = 0
        var contentHeight: CGFloat = 0
        var containerHeight: CGFloat = 0
    }

    /// This app has exactly one window, so there's no ambiguity to resolve —
    /// just find it by type rather than plumbing a reference down through
    /// the view hierarchy.
    private var widgetWindow: NSWindow? {
        NSApp.windows.first { $0 is FloatingWidgetWindow }
    }

    private func queueMessage(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.custom("Monaco", size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
    }

    // MARK: - Click wheel hit targets

    private var wheelCenter: CGPoint { CGPoint(x: 147.5 * scale, y: 328.5 * scale) }
    private var wheelDiameter: CGFloat { 169 * scale }
    private var iconRadius: CGFloat { 72 * scale }

    /// Clipped to the wheel's own circle so a pressed button's shadow stays
    /// on the white ring instead of bleeding onto the plain body around it.
    private var wheelHitTargets: some View {
        ZStack {
            hitTarget(diameter: 42, offset: CGPoint(x: 0, y: -iconRadius)) {
                showingQueue.toggle()
                viewModel.setQueueVisible(showingQueue)
            }
            hitTarget(diameter: 42, offset: CGPoint(x: -iconRadius, y: 0)) {
                viewModel.skipPrevious()
            }
            hitTarget(diameter: 42, offset: CGPoint(x: iconRadius, y: 0)) {
                viewModel.skipNext()
            }
            hitTarget(diameter: 42, offset: CGPoint(x: 0, y: iconRadius)) {
                viewModel.togglePlayPause()
            }
            hitTarget(diameter: 50, offset: .zero, clipDiameter: holeDiameter) {
                viewModel.togglePlayPause()
            }
        }
        .frame(width: wheelDiameter, height: wheelDiameter)
        .clipShape(Circle())
        .position(wheelCenter)
        .allowsHitTesting(viewModel.isSourceRunning)
    }

    /// The recessed hole at the wheel's center. Sized from the traced
    /// reference (84×84 against a 375-wide device), via the same
    /// `deviceBounds.width / 375` reference scale used for the screen bezel
    /// above — the earlier pixel-guessed value (83 against the 295-wide
    /// canvas) was noticeably too large relative to the actual device.
    private var holeDiameter: CGFloat { 84 * deviceBounds.width / 375 }

    private func hitTarget(diameter: CGFloat, offset: CGPoint, clipDiameter: CGFloat? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(.clear)
                .contentShape(Circle())
        }
        .buttonStyle(WheelButtonStyle(diameter: diameter, clipDiameter: clipDiameter))
        .frame(width: diameter, height: diameter)
        .offset(x: offset.x, y: offset.y)
    }
}

/// Darkens the tapped spot with a soft radial fade (no hard edge) so a click
/// reads as gentle shading pushed into the wheel, rather than a sticker
/// dropped on top — `.multiply` lets it shade the artwork underneath instead
/// of sitting as a flat, opaque disc. `clipDiameter`, when set, caps the glow
/// to a specific circle (e.g. the wheel's center hole) instead of letting it
/// grow past `diameter` on its own.
private struct WheelButtonStyle: ButtonStyle {
    let diameter: CGFloat
    var clipDiameter: CGFloat? = nil

    private var visualDiameter: CGFloat { diameter * 1.7 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(glow(pressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }

    @ViewBuilder
    private func glow(pressed: Bool) -> some View {
        let fade = Circle()
            .fill(
                RadialGradient(
                    colors: [.black.opacity(pressed ? 0.16 : 0), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: visualDiameter / 2
                )
            )
            .blendMode(.multiply)
            .frame(width: visualDiameter, height: visualDiameter)

        if let clipDiameter {
            fade.mask(Circle().frame(width: clipDiameter, height: clipDiameter))
        } else {
            fade
        }
    }
}
