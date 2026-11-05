import AppKit
import SwiftUI

/// Borderless floating panel that slides in like the AirPods "connected" card.
final class PopupPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        // The window shadow follows the rectangular frame, not the rounded card, so leave it off.
        hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class PopupController {
    private let panel = PopupPanel()
    private let hosting: NSHostingView<AnyView>
    private var hideTimer: Timer?
    private var clickMonitor: Any?
    private let cornerRadius: CGFloat = 26

    var isVisible: Bool { panel.isVisible }

    init(link: BudsLink) {
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.rootView = AnyView(PopupView(
            link: link,
            onClose: { [weak self] in self?.hide() },
            onOpenBluetoothSettings: { [weak self] in
                self?.hide()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
            }
        ))

        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        // A clear container clipped to the card's shape, so the material behind it can't
        // show through in the square corners of the window.
        let container = NSView(frame: hosting.frame)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.cornerRadius = cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true

        let background: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: hosting.frame)
            glass.cornerRadius = cornerRadius
            glass.contentView = hosting
            background = glass
        } else {
            let blur = NSVisualEffectView(frame: hosting.frame)
            blur.material = .popover
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.maskImage = Self.roundedMask(radius: cornerRadius)
            blur.addSubview(hosting)
            background = blur
        }
        background.autoresizingMask = [.width, .height]
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(background)
        panel.contentView = container
        panel.setContentSize(size)
    }

    /// Stretchable rounded-rect mask for NSVisualEffectView, which ignores layer corner clipping.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func toggle(below button: NSStatusBarButton) {
        isVisible ? hide() : show(below: button, autoHide: false)
    }

    /// Shows the card under the status item, or in the top-right corner when `button` is nil.
    func show(below button: NSStatusBarButton?, autoHide: Bool) {
        let size = hosting.fittingSize
        panel.setContentSize(size)

        let screen = button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: NSPoint
        if let button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: buttonFrame.midX - size.width / 2, y: visible.maxY - size.height - 8)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 14, y: visible.maxY - size.height - 10)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)

        let finalFrame = NSRect(origin: origin, size: size)
        if !panel.isVisible {
            panel.setFrame(finalFrame.offsetBy(dx: 0, dy: 14), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }

        installClickMonitor()
        hideTimer?.invalidate()
        hideTimer = nil
        if autoHide { scheduleAutoHide(after: 8) }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }

    private func scheduleAutoHide(after seconds: TimeInterval) {
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Stay open while the pointer is over the card.
                if self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.scheduleAutoHide(after: 2)
                } else {
                    self.hide()
                }
            }
        }
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
}
