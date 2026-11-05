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
            Image(systemName: "earbuds")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.primary.opacity(connected ? 0.9 : 0.35))
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
                .frame(height: 76)
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
            BatteryRing(title: "Left", symbol: "earbud.left", battery: connected ? link.left : nil)
            BatteryRing(title: "Right", symbol: "earbud.right", battery: connected ? link.right : nil)
            BatteryRing(title: link.caseBattery != nil && !link.caseIsLive ? "Case (last)" : "Case",
                        symbol: "earbuds.case",
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
            // Always laid out so the card keeps its size; only active in Noise Cancellation.
            LevelPicker(selected: link.noiseMode == .anc ? link.ancLevel : nil) { level in
                withAnimation(.snappy) { link.setAncLevel(level) }
            }
            .disabled(link.noiseMode != .anc)
            .opacity(link.noiseMode == .anc ? 1 : 0.4)
        }
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
    let symbol: String
    let battery: BatteryLevel?
    var dimmed = false

    private var fraction: Double { Double(battery?.level ?? 0) / 100 }

    private var color: Color {
        guard let battery else { return .secondary }
        if battery.charging || battery.level > 20 { return .green }
        return battery.level > 10 ? .orange : .red
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: fraction)
                Image(systemName: symbol)
                    .font(.system(size: 19))
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
