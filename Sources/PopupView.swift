import SwiftUI

struct PopupView: View {
    @ObservedObject var link: BudsLink
    var onClose: () -> Void
    var onOpenBluetoothSettings: () -> Void

    // State is spelled out because Command Line Tools ship without the @State macro plugin.
    private let appearedState = State(initialValue: false)
    private var appeared: Bool {
        get { appearedState.wrappedValue }
        nonmutating set { appearedState.wrappedValue = newValue }
    }

    private var connected: Bool { link.phase != .disconnected }

    private var statusLine: String {
        switch link.phase {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting…"
        case .ready:
            guard let mode = link.noiseMode else { return "Connected" }
            if mode == .anc, let level = link.ancLevel { return "Connected · \(mode.title) · \(level.title)" }
            return "Connected · \(mode.title)"
        case .unavailable: return "Connected · controls unavailable"
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            BudsHero(height: 84)
                .opacity(connected ? 1 : 0.4)
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
                .frame(height: 88)
            batteries
            noiseControl
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(width: 372)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65).delay(0.05)) { appeared = true }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.displayName)
                    .font(.system(.headline, design: .rounded))
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
    }

    private var batteries: some View {
        HStack(spacing: 28) {
            BatteryRing(title: "Left", symbol: "earbud.left", photo: BudImages.left,
                        battery: connected ? link.left : nil)
            BatteryRing(title: "Right", symbol: "earbud.right", photo: BudImages.right,
                        battery: connected ? link.right : nil)
            BatteryRing(title: link.caseBattery != nil && !link.caseIsLive ? "Case (last)" : "Case",
                        symbol: "earbuds.case", photo: BudImages.case, photoIsWide: true,
                        battery: connected ? link.caseBattery : nil, dimmed: !link.caseIsLive)
        }
    }

    private var noiseControl: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(NoiseMode.allCases) { mode in
                    ModeButton(mode: mode, selected: link.noiseMode == mode) {
                        withAnimation(.snappy) { link.setNoiseMode(mode) }
                    }
                }
            }
            // Only shown in Noise Cancellation; PopupController resizes the card to fit.
            if link.noiseMode == .anc {
                LevelPicker(selected: link.ancLevel) { level in
                    withAnimation(.snappy) { link.setAncLevel(level) }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: link.noiseMode)
        .padding(8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(!link.canChangeNoiseMode)
        .opacity(link.canChangeNoiseMode ? 1 : 0.45)
        .overlay(alignment: .bottom) {
            if let hint = noiseHint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .offset(y: 16)
                    .transition(.opacity)
            }
        }
        .padding(.bottom, noiseHint == nil ? 0 : 10)
    }

    private var noiseHint: String? {
        if let error = link.lastError { return error }
        if link.phase == .ready, link.inEar == false { return "Put an earbud in to change modes" }
        return nil
    }

    private var footer: some View {
        HStack {
            if connected {
                Button("Disconnect") { link.disconnect() }
            } else {
                Button("Connect") { link.connect() }
                    .disabled(link.device == nil)
            }
            Spacer()
            Button("Bluetooth Settings…", action: onOpenBluetoothSettings)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

struct BatteryRing: View {
    let title: String
    /// Fallback when the photo isn't bundled.
    let symbol: String
    var photo: NSImage?
    /// The case is wider than tall, so it's sized by width instead of height.
    var photoIsWide = false
    let battery: BatteryLevel?
    var dimmed = false

    private var fraction: Double { Double(battery?.level ?? 0) / 100 }

    private var color: Color { batteryColor(battery) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: fraction)
                if let photo {
                    Image(nsImage: photo)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: photoIsWide ? 32 : nil, height: photoIsWide ? nil : 32)
                        // Light edge so the dark photo stands out on dark glass, as elsewhere.
                        .shadow(color: .white.opacity(0.4), radius: 0.6)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 19))
                }
                if battery?.charging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(.green))
                        .offset(x: 19, y: -19)
                }
            }
            .frame(width: 54, height: 54)
            Text(battery.map { "\($0.level)%" } ?? "—")
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .opacity(dimmed && battery != nil ? 0.5 : 1)
    }
}

struct ModeButton: View {
    let mode: NoiseMode
    let selected: Bool
    let action: () -> Void

    private let hoveringState = State(initialValue: false)
    private var hovering: Bool {
        get { hoveringState.wrappedValue }
        nonmutating set { hoveringState.wrappedValue = newValue }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(selected ? AnyShapeStyle(Color.accentColor)
                                       : AnyShapeStyle(.primary.opacity(hovering ? 0.14 : 0.08)))
                    Image(systemName: mode.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(selected ? .white : .primary)
                }
                .frame(width: 44, height: 44)
                Text(mode.title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct LevelPicker: View {
    let selected: AncLevel?
    let action: (AncLevel) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AncLevel.allCases) { level in
                let isSelected = selected == level
                Button { action(level) } label: {
                    Text(level.title)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(isSelected ? AnyShapeStyle(Color.accentColor)
                                                      : AnyShapeStyle(.primary.opacity(0.06)))
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Noise cancellation level")
    }
}

/// Green while charging or above 20%, then orange, then red at 10% and below.
func batteryColor(_ battery: BatteryLevel?) -> Color {
    guard let battery else { return .secondary }
    if battery.charging || battery.level > 20 { return .green }
    return battery.level > 10 ? .orange : .red
}

/// What the compact pill is announcing.
@MainActor
final class BannerState: ObservableObject {
    enum Kind: Equatable {
        case connected
        case lowBattery(BatteryLevel)
    }

    @Published var kind: Kind = .connected
}

/// Compact pill that drops down when the earbuds connect or run low.
/// Clicking opens the full card.
struct ConnectedBanner: View {
    @ObservedObject var link: BudsLink
    @ObservedObject var state: BannerState
    var onOpen: () -> Void

    /// The earbud that ran low, or otherwise the lower of the two.
    private var battery: BatteryLevel? {
        if case .lowBattery(let level) = state.kind { return level }
        return [link.left, link.right].compactMap { $0 }.min { $0.level < $1.level }
    }

    @ViewBuilder private var subtitle: some View {
        switch state.kind {
        case .lowBattery(let level):
            Text("Low Battery")
                .foregroundStyle(level.level <= 10 ? Color.red : Color.orange)
                .fontWeight(.medium)
        case .connected:
            Text(link.phase == .disconnected ? "Disconnected" : "Connected")
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            BudsIcon(size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(link.displayName)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                subtitle
                    .font(.caption)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: Double(battery?.level ?? 0) / 100)
                    .stroke(batteryColor(battery), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: battery?.level)
                Text(battery.map { "\($0.level)" } ?? "–")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.kind == .connected ? AnyShapeStyle(.secondary)
                                                              : AnyShapeStyle(batteryColor(battery)))
            }
            .frame(width: 34, height: 34)
            .accessibilityLabel(battery.map { "Battery \($0.level) percent" } ?? "Battery unknown")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .frame(width: 280)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .animation(.snappy, value: state.kind)
        .help("Show battery and noise control")
    }
}

/// Cut-outs of the earbuds, bundled in Resources. `BUDSPOP_RESOURCES` points elsewhere for previews.
enum BudImages {
    static let left = load("bud-left")
    static let right = load("bud-right")
    static let `case` = load("case")

    /// The two buds side by side as a template image: macOS uses only the outline and tints it
    /// to match the menu bar, as it does for every other status icon.
    static let menuBarIcon: NSImage? = {
        guard let left, let right else { return nil }
        let height: CGFloat = 16
        let budWidth = height * left.size.width / left.size.height
        let gap: CGFloat = 1.5
        let icon = NSImage(size: NSSize(width: budWidth * 2 + gap, height: height), flipped: false) { _ in
            left.draw(in: NSRect(x: 0, y: 0, width: budWidth, height: height))
            right.draw(in: NSRect(x: budWidth + gap, y: 0, width: budWidth, height: height))
            return true
        }
        icon.isTemplate = true
        icon.accessibilityDescription = "Earbuds"
        return icon
    }()

    private static func load(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        if let dir = ProcessInfo.processInfo.environment["BUDSPOP_RESOURCES"] {
            return NSImage(contentsOfFile: dir + "/" + name + ".png")
        }
        return nil
    }
}

/// Two tilted earbuds, one up-left and one down-right in front, for the pill.
struct BudsIcon: View {
    var size: CGFloat

    var body: some View {
        if let left = BudImages.left, let right = BudImages.right {
            ZStack {
                bud(left).offset(x: -size * 0.17, y: -size * 0.12)
                bud(right).offset(x: size * 0.17, y: size * 0.12)
            }
            .frame(width: size, height: size)
        } else {
            Image(systemName: "earbuds")
                .font(.system(size: size * 0.62))
                .frame(width: size, height: size)
        }
    }

    private func bud(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: size * 0.74)
            .rotationEffect(.degrees(28))
            // The buds are dark grey, so a faint light edge keeps them readable on dark glass.
            .shadow(color: .white.opacity(0.45), radius: 0.6)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
}

/// The two earbuds standing upright side by side, for the full card.
struct BudsHero: View {
    var height: CGFloat

    var body: some View {
        if let left = BudImages.left, let right = BudImages.right {
            HStack(spacing: height * 0.08) {
                bud(left)
                bud(right)
            }
        } else {
            Image(systemName: "earbuds")
                .font(.system(size: height * 0.76, weight: .light))
                .foregroundStyle(.primary.opacity(0.9))
        }
    }

    private func bud(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(height: height)
            // Same light edge as the pill icon, so the dark buds stand out on dark glass.
            .shadow(color: .white.opacity(0.4), radius: 0.8)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
    }
}
