import Foundation
import IOBluetooth

// Talks to OnePlus / OPPO / realme earbuds over their vendor RFCOMM channel.
// Frame format follows the oppo-pods Noctalia plugin; the subscription and wear-state commands
// follow Gadgetbridge's OPPO headphones support. Noise-mode codes were verified on the
// OnePlus Buds 4 by reading the mode back after each change.

enum NoiseMode: String, CaseIterable, Identifiable {
    case off, transparency, adaptive, anc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .transparency: "Transparency"
        case .adaptive: "Adaptive"
        case .anc: "Noise Cancellation"
        }
    }

    var symbol: String {
        switch self {
        case .off: "circle.slash"
        case .transparency: "ear.badge.waveform"
        case .adaptive: "circle.lefthalf.filled"
        case .anc: "waveform.slash"
        }
    }

    /// Value sent to switch modes. Noise Cancellation returns to whichever level was last used.
    var setValue: UInt16 {
        switch self {
        case .off: 0x0001
        case .transparency: 0x0004
        case .adaptive: 0x0800
        case .anc: 0x0002
        }
    }
}

/// Noise-cancellation strength. The same code is used to set it and is reported back.
enum AncLevel: String, CaseIterable, Identifiable {
    case auto, low, moderate, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }

    var value: UInt16 {
        switch self {
        case .auto: 0x0080  // the earbuds adjust the strength themselves in this mode
        case .low: 0x0040
        case .moderate: 0x0020
        case .high: 0x0010
        }
    }
}

struct BatteryLevel: Equatable {
    var level: Int
    var charging: Bool
}

enum LinkPhase: Equatable {
    case disconnected
    case connecting
    case ready
    case unavailable(String)
}

@MainActor
final class BudsLink: NSObject, ObservableObject {
    static let nameKeywords = ["oneplus", "oppo", "enco", "realme", "dizo"]

    static let modelNames: [String: String] = [
        "067C10": "OPPO Enco Air4 Pro", "069010": "OPPO Enco Air4", "064C10": "OPPO Enco Air3",
        "065C10": "OPPO Enco Air3 Pro", "063410": "OPPO Enco Air2", "063810": "OPPO Enco Air2 Pro",
        "066010": "OPPO Enco Free3", "068C10": "OPPO Enco Free4", "06C010": "OPPO Enco Free4 Dynaudio",
        "068010": "OPPO Enco Buds2 Pro", "06A450": "OPPO Enco Buds3", "046410": "OnePlus Buds Pro 2",
        "046810": "OnePlus Buds Pro 3", "045010": "OnePlus Buds 3", "045410": "OnePlus Buds Pro",
        "044810": "OnePlus Buds Z2", "055010": "realme Buds Air 5 Pro", "056010": "realme Buds Air 6 Pro",
        "054410": "realme Buds T300", "054810": "realme Buds T310", "065414": "OnePlus Buds 4",
    ]

    @Published private(set) var device: IOBluetoothDevice?
    @Published private(set) var phase: LinkPhase = .disconnected
    @Published private(set) var left: BatteryLevel?
    @Published private(set) var right: BatteryLevel?
    @Published private(set) var caseBattery: BatteryLevel?
    @Published private(set) var caseIsLive = false
    @Published private(set) var noiseMode: NoiseMode?
    @Published private(set) var ancLevel: AncLevel?
    @Published private(set) var productID: String?
    /// nil until the earbuds report wear state; newer models only accept mode changes while worn.
    @Published private(set) var inEar: Bool?
    @Published private(set) var lastError: String?

    /// Called once per connection, after the first battery report (or a short timeout).
    var onAnnounce: (() -> Void)?
    /// Called when an earbud that isn't charging drops below 20%, and again at 10%.
    var onLowBattery: ((BatteryLevel) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNote: IOBluetoothUserNotification?
    private var channel: IOBluetoothRFCOMMChannel?
    private var pendingChannelIDs: [BluetoothRFCOMMChannelID] = []
    private var buffer = Data()
    private var seq: UInt8 = 0
    private var pollTimer: Timer?
    private var announcePending = false
    /// The warning threshold already shown (20 or 10); cleared once the earbuds are above 20% again.
    private var lowBatteryWarned: Int?
    private var reopenAttempts = 0
    private var openingChannelID: BluetoothRFCOMMChannelID?
    private var channelVerified = false
    private var channelTimeout: DispatchWorkItem?

    var displayName: String { device?.name ?? "Earbuds" }
    var isConnected: Bool { device?.isConnected() ?? false }

    var preferredAddress: String? {
        get { UserDefaults.standard.string(forKey: "deviceAddress") }
        set {
            UserDefaults.standard.set(newValue, forKey: "deviceAddress")
            rescan()
        }
    }

    // MARK: Device discovery

    func start() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                                                 selector: #selector(deviceDidConnect(_:device:)))
        rescan()
    }

    static func pairedAudioDevices() -> [IOBluetoothDevice] {
        let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return all.filter { $0.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio) }
    }

    private func candidates() -> [IOBluetoothDevice] {
        let all = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        if let address = preferredAddress {
            return all.filter { $0.addressString == address }
        }
        return all.filter { device in
            let name = (device.name ?? "").lowercased()
            return Self.nameKeywords.contains { name.contains($0) }
        }
    }

    private func rescan() {
        let list = candidates()
        if let current = device, !list.contains(where: { $0.addressString == current.addressString }) {
            detach()
            device = nil
        }
        if let connected = list.first(where: { $0.isConnected() }) {
            attach(connected, announce: false)
        } else if device == nil {
            device = list.first
        }
    }

    // IOBluetooth may call these on its own queue, so every entry point hops to the main thread.
    @objc nonisolated private func deviceDidConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMain { self.handleConnect(device) }
    }

    @objc nonisolated private func deviceDidDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        onMain { self.handleDisconnect(device) }
    }

    @objc nonisolated func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        onMain {
            Log.write("connectionComplete status \(status)")
            if status != kIOReturnSuccess { self.phase = .disconnected }
        }
    }

    private func handleConnect(_ device: IOBluetoothDevice) {
        guard candidates().contains(where: { $0.addressString == device.addressString }) else { return }
        Log.write("connected: \(device.name ?? "?") \(device.addressString ?? "")")
        attach(device, announce: true)
    }

    private func handleDisconnect(_ device: IOBluetoothDevice) {
        Log.write("disconnected: \(device.name ?? "?")")
        disconnectNote?.unregister()
        disconnectNote = nil
        detach()
        phase = .disconnected
        objectWillChange.send()
    }

    private func attach(_ newDevice: IOBluetoothDevice, announce: Bool) {
        // IOBluetooth can report the same connection more than once.
        if device?.addressString == newDevice.addressString, phase != .disconnected { return }
        detach()
        device = newDevice
        disconnectNote?.unregister()
        disconnectNote = newDevice.register(forDisconnectNotification: self,
                                            selector: #selector(deviceDidDisconnect(_:device:)))
        phase = .connecting
        reopenAttempts = 0
        announcePending = announce
        if announce {
            // Show the pop-up even if the earbuds never answer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.announceIfPending() }
        }
        // Let the audio profiles settle before opening the control channel.
        DispatchQueue.main.asyncAfter(deadline: .now() + (announce ? 1.2 : 0.1)) { [weak self] in
            self?.openControlChannel()
        }
    }

    private func detach() {
        pollTimer?.invalidate()
        pollTimer = nil
        pendingChannelIDs = []
        channelTimeout?.cancel()
        channelTimeout = nil
        openingChannelID = nil
        channelVerified = false
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        channel = nil
        buffer.removeAll()
        noiseMode = nil
        ancLevel = nil
        caseIsLive = false
        inEar = nil
        lastError = nil
        lowBatteryWarned = nil
    }

    private func announceIfPending() {
        guard announcePending else { return }
        announcePending = false
        onAnnounce?()
    }

    // MARK: Connect / disconnect

    func connect() {
        guard let device, !device.isConnected() else { return }
        phase = .connecting
        let result = device.openConnection(self)
        Log.write("openConnection -> \(result)")
    }


    func disconnect() {
        guard let device else { return }
        detach()
        device.closeConnection()
        phase = .disconnected
    }

    // MARK: RFCOMM channel

    private func openControlChannel(attempt: Int = 0) {
        guard let device, channel == nil, phase != .disconnected else { return }
        guard device.isConnected() else {
            // The connect notification can arrive before the link is fully up.
            guard attempt < 10 else { return }
            Log.write("waiting for link (attempt \(attempt + 1))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openControlChannel(attempt: attempt + 1)
            }
            return
        }
        pendingChannelIDs = channelCandidates(for: device)
        Log.write("trying RFCOMM channels \(pendingChannelIDs)")
        tryNextChannel()
    }

    private var rememberedChannelKey: String { "channel-\(device?.addressString ?? "")" }

    /// Channels to probe, most likely first: the one that worked last time, the vendor
    /// service advertised over SDP ("enco link" on newer models), then the legacy 12/13.
    private func channelCandidates(for device: IOBluetoothDevice) -> [BluetoothRFCOMMChannelID] {
        var vendor: [BluetoothRFCOMMChannelID] = []
        var others: [BluetoothRFCOMMChannelID] = []
        for case let record as IOBluetoothSDPServiceRecord in device.services ?? [] {
            var id: BluetoothRFCOMMChannelID = 0
            guard record.getRFCOMMChannelID(&id) == kIOReturnSuccess else { continue }
            let name = record.getServiceName() ?? ""
            let uuids = (record.getAttributeDataElement(1)?.getArrayValue() as? [IOBluetoothSDPDataElement] ?? [])
                .compactMap { $0.getUUIDValue() }
            let hasVendorUUID = uuids.contains { uuid in
                let bytes = [UInt8](uuid as Data)
                return bytes.count == 16 && bytes[0...3] == [0x00, 0x00, 0x07, 0x9A]
            }
            let isVendor = hasVendorUUID || ["enco", "oppo", "melody"].contains { name.lowercased().contains($0) }
            Log.write("SDP '\(name.isEmpty ? "?" : name)' channel \(id)\(isVendor ? " (vendor)" : "")")
            if isVendor { vendor.append(id) } else if !name.isEmpty { others.append(id) }
        }
        let remembered = UserDefaults.standard.integer(forKey: rememberedChannelKey)
        let first = remembered > 0 ? [BluetoothRFCOMMChannelID(remembered)] : []
        var ids: [BluetoothRFCOMMChannelID] = []
        for id in first + vendor + [12, 13] + others where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private func tryNextChannel() {
        guard let device, device.isConnected() else { return }
        guard !pendingChannelIDs.isEmpty else {
            phase = .unavailable("Couldn't reach the earbuds' controls")
            announceIfPending()
            return
        }
        let id = pendingChannelIDs.removeFirst()
        openingChannelID = id
        channelVerified = false
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: id, delegate: self)
        Log.write("open channel \(id) -> \(result)")
        guard result == kIOReturnSuccess, let opened else {
            abandonChannel()
            return
        }
        if channel == nil { channel = opened }
        armChannelTimeout(seconds: 4, reason: "open timed out")
    }

    /// Gives up on the current channel if it doesn't open, or opens but never answers.
    private func armChannelTimeout(seconds: Double, reason: String) {
        channelTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.channelVerified else { return }
            Log.write("channel \(self.openingChannelID ?? 0): \(reason)")
            self.abandonChannel()
        }
        channelTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func abandonChannel() {
        channelTimeout?.cancel()
        if let channel {
            channel.setDelegate(nil)
            channel.close()
        }
        channel = nil
        openingChannelID = nil
        tryNextChannel()
    }

    private func channelDidOpen(_ opened: IOBluetoothRFCOMMChannel, status: IOReturn) {
        // The callback can arrive before openRFCOMMChannelAsync returns, so match by ID.
        guard opened.getID() == openingChannelID else { return }
        channel = opened
        guard status == kIOReturnSuccess else {
            Log.write("channel \(opened.getID()) failed: \(status)")
            abandonChannel()
            return
        }
        Log.write("channel \(opened.getID()) open, waiting for a reply")
        buffer.removeAll()
        refresh(full: true)
        armChannelTimeout(seconds: 3, reason: "no reply")
    }

    private func channelVerifiedByReply() {
        guard !channelVerified, let channel else { return }
        channelVerified = true
        channelTimeout?.cancel()
        Log.write("channel \(channel.getID()) answered; using it")
        UserDefaults.standard.set(Int(channel.getID()), forKey: rememberedChannelKey)
        phase = .ready
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(full: false) }
        }
    }

    private func channelDidClose(_ closed: IOBluetoothRFCOMMChannel) {
        guard closed === channel else { return }
        Log.write("channel \(closed.getID()) closed")
        guard channelVerified else {
            // Closed while probing: move on to the next candidate.
            channel = nil
            abandonChannel()
            return
        }
        channel = nil
        channelVerified = false
        pollTimer?.invalidate()
        guard isConnected, reopenAttempts < 3 else {
            phase = isConnected ? .unavailable("Lost the control channel") : .disconnected
            return
        }
        reopenAttempts += 1
        phase = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.openControlChannel() }
    }

    // MARK: Commands

    var canChangeNoiseMode: Bool { phase == .ready && inEar != false }

    func refresh(full: Bool) {
        var commands: [(UInt16, [UInt8])] = [(0x0100, [])]
        if full {
            commands.append((0x0103, []))
            // Subscribe to pushed battery, wear-state and noise-mode changes.
            commands.append((0x0205, [0x09, 0x01, 0x02, 0x03]))
        }
        commands.append((0x0106, []))
        commands.append((0x0109, []))
        commands.append((0x010C, [0x01, 0x01]))
        sendSequence(commands)
    }

    func setNoiseMode(_ mode: NoiseMode) {
        guard canChangeNoiseMode else { return }
        lastError = nil
        noiseMode = mode
        sendNoiseValue(mode.setValue)
    }

    func setAncLevel(_ level: AncLevel) {
        guard canChangeNoiseMode else { return }
        lastError = nil
        noiseMode = .anc
        ancLevel = level
        sendNoiseValue(level.value)
    }

    /// Values above 0xFF go out as two little-endian bytes (Adaptive is 0x0800).
    private func sendNoiseValue(_ value: UInt16) {
        var payload: [UInt8] = [0x01, 0x01, UInt8(value & 0xFF)]
        if value > 0xFF { payload.append(UInt8(value >> 8)) }
        sendSequence([(0x0404, payload)])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.sendSequence([(0x010C, [0x01, 0x01])])
        }
    }

    private func sendSequence(_ commands: [(UInt16, [UInt8])]) {
        for (index, command) in commands.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(index)) { [weak self] in
                self?.send(command.0, payload: command.1)
            }
        }
    }

    private func send(_ command: UInt16, payload: [UInt8]) {
        guard let channel, channel.isOpen() else { return }
        seq &+= 1
        var frame: [UInt8] = [
            0xAA, UInt8((payload.count + 7) & 0xFF), 0x00, 0x00,
            UInt8(command & 0xFF), UInt8(command >> 8),
            seq,
            UInt8(payload.count & 0xFF), UInt8(payload.count >> 8),
        ]
        frame += payload
        let result = frame.withUnsafeMutableBytes { raw in
            channel.writeSync(raw.baseAddress, length: UInt16(raw.count))
        }
        Log.write("-> \(Log.hex(frame)) [\(result)]")
    }

    // MARK: Parsing

    private func receive(_ data: Data) {
        Log.write("<- \(Log.hex([UInt8](data)))")
        buffer.append(data)
        var bytes = [UInt8](buffer)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0xAA else { index += 1; continue }
            guard index + 9 <= bytes.count else { break }
            let payloadLength = Int(bytes[index + 7]) | Int(bytes[index + 8]) << 8
            if payloadLength > 1024 { index += 1; continue }
            let end = index + 9 + payloadLength
            guard end <= bytes.count else { break }
            let command = UInt16(bytes[index + 4]) | UInt16(bytes[index + 5]) << 8
            channelVerifiedByReply()
            handle(command: command, payload: Array(bytes[(index + 9)..<end]))
            index = end
        }
        bytes.removeFirst(min(index, bytes.count))
        buffer = Data(bytes)
    }

    private func handle(command: UInt16, payload p: [UInt8]) {
        switch command {
        case 0x8103:
            if p.count >= 4, p[0] == 0 {
                productID = String(format: "%02X%02X%02X", p[3], p[2], p[1])
                Log.write("product id \(productID!)")
            }
        case 0x8106:
            parseBattery(p, isFullReport: true)
        case 0x8109:
            parseWearState(p)
        case 0x810C:
            parseNoise(p)
        case 0x8404:
            // Ack for a mode change: 0 is success, anything else is a refusal.
            if let status = p.first, status != 0 {
                Log.write("noise mode change refused (0x\(String(format: "%02X", status)))")
                lastError = inEar == false ? "Put an earbud in to change modes"
                                           : "Not available right now. Try wearing both earbuds"
            }
        case 0x0204:
            // Pushed update: the first byte names the subscription, the rest matches the reply format.
            switch p.first {
            case 0x01: parseBattery(p, isFullReport: false)
            case 0x02: parseWearState(p)
            case 0x03: parseNoise(p)
            default: break
            }
        default:
            break
        }
    }

    private func parseBattery(_ p: [UInt8], isFullReport: Bool) {
        guard p.count >= 4 else { return }
        let count = Int(p[1])
        // An earbud in the case is left out of the reply; don't keep showing its old level.
        if isFullReport {
            let ids = stride(from: 2, to: min(p.count - 1, 2 + count * 2), by: 2).map { p[$0] }
            if !ids.contains(1) { left = nil }
            if !ids.contains(2) { right = nil }
        }
        var i = 2
        while i + 1 < p.count, i < 2 + count * 2 {
            defer { i += 2 }
            if p[i + 1] == 0xFF { continue }
            let value = BatteryLevel(level: Int(p[i + 1] & 0x7F), charging: p[i + 1] & 0x80 != 0)
            switch p[i] {
            case 1: left = value
            case 2: right = value
            case 3:
                // A closed case reports 0; keep the last known level but mark it stale.
                if value.level > 0 || value.charging {
                    caseBattery = value
                    caseIsLive = true
                } else {
                    caseIsLive = false
                }
            default: break
            }
        }
        announceIfPending()
        checkLowBattery()
    }

    private func checkLowBattery() {
        let worn = [left, right].compactMap { $0 }.filter { !$0.charging }
        guard let lowest = worn.min(by: { $0.level < $1.level }), lowest.level < 20 else {
            lowBatteryWarned = nil
            return
        }
        let threshold = lowest.level <= 10 ? 10 : 20
        guard lowBatteryWarned.map({ threshold < $0 }) ?? true else { return }
        lowBatteryWarned = threshold
        Log.write("low battery: \(lowest.level)%")
        onLowBattery?(lowest)
    }

    /// Payload: [0 or subscription type, count, (side, state)...]. Sides 1/2 are the buds, 3 the case.
    /// Gadgetbridge documents 0 = in case, 1 = out of ear, 3 = worn; the Buds 4 also send 5 for a
    /// worn bud, so anything that isn't "in case" or "out of ear" counts as worn.
    private func parseWearState(_ p: [UInt8]) {
        guard p.count >= 2 else { return }
        var buds: [UInt8] = []
        var i = 2
        while i + 1 < p.count, i < 2 + Int(p[1]) * 2 {
            if p[i] == 1 || p[i] == 2 { buds.append(p[i + 1]) }
            i += 2
        }
        guard !buds.isEmpty else { return }
        inEar = buds.contains { $0 != 0x00 && $0 != 0x01 }
        if inEar == true { lastError = nil }
        Log.write("wear state \(Log.hex(buds)) -> in ear: \(inEar!)")
    }

    /// Payload: [0 or subscription type, config type, 0x01, value lo, value hi]; only type 1 (mode) is used.
    /// The reported value can differ from the one that was set: Off reads back as 0x0008 and
    /// Transparency as 0x0100 or 0x0200; Noise Cancellation reads back as its level.
    private func parseNoise(_ p: [UInt8]) {
        guard p.count >= 4, p[1] == 0x01 else { return }
        let value = UInt16(p[3]) | (p.count > 4 ? UInt16(p[4]) << 8 : 0)
        if let level = AncLevel.allCases.first(where: { $0.value == value }) {
            noiseMode = .anc
            ancLevel = level
            return
        }
        switch value {
        case 0x0001, 0x0008: noiseMode = .off
        case 0x0004, 0x0100, 0x0200: noiseMode = .transparency
        case 0x0800: noiseMode = .adaptive
        case 0x0002: noiseMode = .anc
        default: Log.write("unknown noise mode 0x\(String(format: "%04X", value))")
        }
    }
}

#if PREVIEW
extension BudsLink {
    func loadPreviewData() {
        phase = .ready
        left = BatteryLevel(level: 82, charging: false)
        right = BatteryLevel(level: 17, charging: false)
        caseBattery = BatteryLevel(level: 64, charging: true)
        caseIsLive = true
        noiseMode = .anc
        ancLevel = .moderate
    }
}
#endif

extension BudsLink: IOBluetoothRFCOMMChannelDelegate {
    nonisolated func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        onMain { self.channelDidOpen(rfcommChannel, status: error) }
    }

    nonisolated func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                                       data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        let data = Data(bytes: dataPointer, count: dataLength)
        onMain {
            guard rfcommChannel.getID() == self.openingChannelID else { return }
            self.receive(data)
        }
    }

    nonisolated func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        onMain { self.channelDidClose(rfcommChannel) }
    }
}

/// Runs `work` on the main actor: inline when already on the main thread, otherwise queued.
private func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BudsPop.log")

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
