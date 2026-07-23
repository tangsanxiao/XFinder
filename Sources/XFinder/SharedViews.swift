import SwiftUI

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title2.weight(.semibold))

            Text(description)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WindowChromeConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureIfNeeded(window: view.window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else {
            DispatchQueue.main.async {
                configureIfNeeded(window: nsView.window, coordinator: context.coordinator)
            }
            return
        }
        configureIfNeeded(window: window, coordinator: context.coordinator)
    }

    private func configureIfNeeded(window: NSWindow?, coordinator: Coordinator) {
        guard let window else { return }
        guard coordinator.configuredWindow !== window else { return }

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.toolbar = nil
        coordinator.configuredWindow = window
    }

    final class Coordinator {
        weak var configuredWindow: NSWindow?
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggableWindowView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HostingWindowNumberReader: NSViewRepresentable {
    @Binding var windowNumber: Int?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        updateWindowNumber(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindowNumber(from: nsView)
    }

    private func updateWindowNumber(from view: NSView) {
        DispatchQueue.main.async {
            let newValue = view.window?.windowNumber
            if windowNumber != newValue { windowNumber = newValue }
        }
    }
}

/// Sets the mouse cursor over a region using an AppKit tracking area on a
/// persistent NSView, instead of SwiftUI `.onHover` + cursor push/pop. The
/// push/pop approach lost its pairing during SwiftUI re-renders (the resizable
/// header rebuilds while dragging or scrolling), so the resize cursor
/// flickered or never appeared. A tracking area fires enter/exit purely on
/// geometry (independent of hit testing), and the NSView isn't recreated on
/// SwiftUI re-renders, so the cursor stays stable. `hitTest` returns nil so
/// the overlay never steals the drag gesture beneath it.
private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.cursor = cursor
    }

    static func dismantleNSView(_ nsView: TrackingView, coordinator: ()) {
        nsView.balancePop()
    }

    final class TrackingView: NSView {
        var cursor: NSCursor = .arrow
        private var pushed = false

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                    owner: self
                ))
        }

        override func mouseEntered(with event: NSEvent) {
            guard !pushed else { return }
            cursor.push()
            pushed = true
        }

        override func mouseExited(with event: NSEvent) {
            balancePop()
        }

        func balancePop() {
            guard pushed else { return }
            NSCursor.pop()
            pushed = false
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func hoverCursor(_ cursor: NSCursor) -> some View {
        overlay(CursorRectView(cursor: cursor))
    }

    /// Applies `transform` only when `condition` holds. `condition` must be
    /// stable for the view's lifetime (it changes the view's structural
    /// identity), which fits per-row "is this a folder" drop targeting.
    @ViewBuilder
    func `if`<Transformed: View>(_ condition: Bool, transform: (Self) -> Transformed) -> some View {
        if condition { transform(self) } else { self }
    }
}

enum ResizePhase {
    case began
    case changed
    case ended
}

/// Simple left-to-right wrapping layout (chips, tags). Wraps to the next line
/// when the next subview would overflow the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

extension View {
    /// Left–right column-resize cursor for a divider. Uses SwiftUI's native
    /// `pointerStyle` (macOS 15+), which integrates with SwiftUI's own cursor
    /// management so it doesn't flicker. AppKit overlays inside the SwiftUI
    /// host can't win against NSHostingView's cursor handling, which is why the
    /// earlier tracking-area / cursor-rect attempts flickered or didn't show.
    @ViewBuilder
    func columnResizeCursor() -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.frameResize(position: .trailing))
        } else {
            hoverCursor(.resizeLeftRight)
        }
    }
}

private final class DraggableWindowView: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            WindowZoomController.toggle(window: window)
            return
        }
        window?.performDrag(with: event)
    }
}

/// Single window-level tooltip layer. Native `.help()` doesn't fire reliably
/// in this hidden-title-bar / full-size-content window, so we render our own
/// immediate bubble: controls report their frame + text on hover, and the
/// overlay (installed once in ContentView) positions a bubble clamped inside
/// the window so it never clips at an edge or attaches to the wrong control.
@MainActor
final class TooltipCenter: ObservableObject {
    @Published var text: String?
    @Published var anchor: CGRect = .zero
}

/// Coordinate space shared by the hover-frame capture and the overlay, so the
/// reported anchor and the bubble position use the same origin.
let tooltipCoordinateSpace = "xfRootTooltipSpace"

extension View {
    /// Immediate custom tooltip; works on plain buttons and Menus alike.
    func helpTip(_ text: String) -> some View {
        modifier(HelpTipModifier(text: text))
    }
}

private struct HelpTipModifier: ViewModifier {
    @EnvironmentObject private var center: TooltipCenter
    let text: String
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { frame = proxy.frame(in: .named(tooltipCoordinateSpace)) }
                        .onChange(of: proxy.frame(in: .named(tooltipCoordinateSpace))) { frame = $0 }
                }
            )
            .onHover { hovering in
                if hovering {
                    center.text = text
                    center.anchor = frame
                } else if center.text == text {
                    center.text = nil
                }
            }
    }
}

/// Installed once over the whole window; draws the active tooltip bubble.
struct TooltipOverlay: View {
    @EnvironmentObject private var center: TooltipCenter
    @State private var bubbleSize: CGSize = .zero
    @State private var clickMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            if let text = center.text {
                TooltipBubble(text: text)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.onAppear { bubbleSize = proxy.size }
                                .onChange(of: proxy.size) { bubbleSize = $0 }
                        }
                    )
                    .position(
                        x: clampedX(in: geo.size.width),
                        y: center.anchor.maxY + 6 + bubbleSize.height / 2
                    )
                    .allowsHitTesting(false)
            }
        }
        // Dismiss the tooltip immediately on any click: onHover doesn't re-fire
        // while the cursor stays on a just-clicked button, so without this the
        // bubble lingers until the mouse leaves (worst on the sidebar toggle).
        .onAppear {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                center.text = nil
                return event
            }
        }
        .onDisappear {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }
    }

    private func clampedX(in width: CGFloat) -> CGFloat {
        let half = bubbleSize.width / 2
        return min(max(center.anchor.midX, half + 6), width - half - 6)
    }
}

private struct TooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.85)))
            .fixedSize()
    }
}

/// Icon button for the toolbars, with the custom immediate tooltip.
struct PaneToolbarActionButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let tooltip: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(isHovering ? 0.2 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .helpTip(tooltip)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.08)) {
                isHovering = hovering
            }
        }
    }
}

@MainActor
enum AppRelauncher {
    /// Launches a fresh instance of this app bundle via `open -n`, then
    /// terminates the current one. Debug convenience — only meaningful when
    /// running the packaged `.app`.
    ///
    /// Stays fully synchronous on the main actor on purpose: routing through
    /// `NSWorkspace.openApplication`'s completion handler crashes under Swift 6,
    /// because that handler fires on a background LaunchServices queue while the
    /// closure is MainActor-isolated, tripping `dispatch_assert_queue` (SIGTRAP).
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return
        }
        NSApp.terminate(nil)
    }
}

@MainActor
enum WindowZoomController {
    private static var restoreFrames: [ObjectIdentifier: NSRect] = [:]

    static func toggle(window: NSWindow? = NSApp.keyWindow) {
        guard let window, let screen = window.screen else { return }

        let key = ObjectIdentifier(window)
        if let restoreFrame = restoreFrames[key] {
            window.setFrame(restoreFrame, display: true, animate: true)
            restoreFrames[key] = nil
            return
        }

        restoreFrames[key] = window.frame
        window.setFrame(screen.visibleFrame, display: true, animate: true)
    }
}
