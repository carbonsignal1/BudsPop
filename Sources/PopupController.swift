import AppKit
import Combine
import SwiftUI

/// Borderless floating panel for the controls card and the pop-up pill.
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

    /// AppKit keeps windows out from under the menu bar; the pill starts tucked behind it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Where a floating panel appears when it isn't anchored to the status item.
enum PopupPlacement {
    case topRight
    case topCenter
}

/// How a panel comes in and goes away.
enum PopupEntrance {
    /// Slides down a little and fades (the full card).
    case slide
    /// Drops out from behind the menu bar with a spring, and slides back up under it (the pill).
    case drop
}

/// A glass panel hosting SwiftUI content: used for the full card and the compact "Connected" pill.
@MainActor
final class PopupController {
    private let panel = PopupPanel()
    private let hosting: NSHostingView<AnyView>
    private let placement: PopupPlacement
    private let entrance: PopupEntrance
    private let autoHideDelay: TimeInterval
    private var hideTimer: Timer?
    private var clickMonitor: Any?
    private var contentObservation: AnyCancellable?
    /// Drives the drop animation frame by frame; the window moves, the glass itself is never transformed.
    private var motionTimer: Timer?
    private var isHiding = false

    var isVisible: Bool { panel.isVisible && !isHiding }

    /// `cornerRadius` nil makes a capsule. `content` receives the controller so it can close it.
    init<Content: View>(link: BudsLink, placement: PopupPlacement, entrance: PopupEntrance = .slide,
                        cornerRadius: CGFloat?, autoHideDelay: TimeInterval,
                        content: (PopupController) -> Content) {
        self.placement = placement
        self.entrance = entrance
        self.autoHideDelay = autoHideDelay
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.rootView = AnyView(content(self))

        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let cornerRadius = cornerRadius ?? size.height / 2

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

        if entrance == .drop {
            // Just below the menu bar's level, so the pill slides out from underneath it.
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        }

        // Content can change height (the card's level row), so follow it.
        contentObservation = link.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent() }
        }
    }

    /// Resizes the panel to the SwiftUI content's height, keeping its top edge where it is.
    private func fitToContent() {
        guard panel.isVisible, !isHiding, motionTimer == nil else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let frame = panel.frame
        guard abs(size.height - frame.height) > 0.5 else { return }
        let newFrame = NSRect(x: frame.minX, y: frame.maxY - size.height, width: frame.width, height: size.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
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

    /// Shows the panel under the status item, or at its placement when `button` is nil.
    func show(below button: NSStatusBarButton?, autoHide: Bool, hideAfter: TimeInterval? = nil) {
        let size = hosting.fittingSize
        let screen = button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        var origin: NSPoint
        if let button, let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            origin = NSPoint(x: buttonFrame.midX - size.width / 2, y: visible.maxY - size.height - 8)
        } else {
            switch placement {
            case .topRight:
                // Leaves room at the screen's right edge rather than hugging it.
                origin = NSPoint(x: visible.maxX - size.width - 134, y: visible.maxY - size.height - 8)
            case .topCenter:
                origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8)
            }
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        let finalFrame = NSRect(origin: origin, size: size)

        let wasVisible = isVisible
        switch entrance {
        case .slide:
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
        case .drop:
            if wasVisible {
                panel.setFrame(finalFrame, display: true)
            } else {
                dropIn(to: finalFrame, menuBarBottom: visible.maxY)
            }
        }

        installClickMonitor()
        hideTimer?.invalidate()
        hideTimer = nil
        if autoHide { scheduleAutoHide(after: hideAfter ?? autoHideDelay) }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard panel.isVisible, !isHiding else { return }
        switch entrance {
        case .slide:
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                panel.animator().alphaValue = 0
            }, completionHandler: { [panel] in
                panel.orderOut(nil)
            })
        case .drop:
            dropOut()
        }
    }

    // MARK: Drop animation

    /// Starts tucked behind the menu bar, then springs down into place with a slight settle.
    private func dropIn(to finalFrame: NSRect, menuBarBottom: CGFloat) {
        let startY = menuBarBottom
        panel.setFrame(NSRect(x: finalFrame.minX, y: startY, width: finalFrame.width, height: finalFrame.height),
                       display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        // Under-damped spring: settles in about half a second with a small overshoot.
        let omega = 2 * Double.pi / 0.42
        let zeta = 0.62
        let omegaD = omega * (1 - zeta * zeta).squareRoot()
        animate(duration: 0.62) { [weak self] t in
            guard let self else { return }
            let decay = exp(-zeta * omega * t)
            let progress = 1 - decay * (cos(omegaD * t) + zeta * omega / omegaD * sin(omegaD * t))
            let y = startY + (finalFrame.minY - startY) * progress
            self.panel.setFrameOrigin(NSPoint(x: finalFrame.minX, y: y))
            self.panel.alphaValue = min(1, t / 0.12)
        } completion: { [weak self] in
            self?.panel.setFrame(finalFrame, display: true)
            self?.panel.alphaValue = 1
        }
    }

    /// Lifts back up behind the menu bar, speeding up as it goes, and fades at the end.
    private func dropOut() {
        isHiding = true
        let startFrame = panel.frame
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let endY = screen.visibleFrame.maxY
        let duration = 0.26
        animate(duration: duration) { [weak self] t in
            guard let self else { return }
            let p = t / duration
            let eased = p * p * p
            self.panel.setFrameOrigin(NSPoint(x: startFrame.minX, y: startFrame.minY + (endY - startFrame.minY) * eased))
            self.panel.alphaValue = 1 - max(0, (p - 0.4) / 0.6)
        } completion: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.isHiding = false
        }
    }

    /// Calls `step` with the elapsed time on every frame until `duration` has passed.
    private func animate(duration: Double, step: @escaping @MainActor (Double) -> Void,
                         completion: @escaping @MainActor () -> Void) {
        motionTimer?.invalidate()
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let elapsed = CACurrentMediaTime() - start
                if elapsed >= duration {
                    timer.invalidate()
                    self?.motionTimer = nil
                    completion()
                } else {
                    step(elapsed)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    // MARK: Auto-hide and outside clicks

    private func scheduleAutoHide(after seconds: TimeInterval) {
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Stay open while the pointer is over the panel.
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
