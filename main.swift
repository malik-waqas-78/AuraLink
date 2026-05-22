import Cocoa
import SwiftUI
import IOBluetooth
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine
import ServiceManagement

// Bluetooth Device Model
struct BluetoothDeviceModel: Identifiable, Hashable, Equatable {
    var id: String { address }
    let name: String
    let address: String
    let isConnected: Bool
    let rssi: Int
    
    static func == (lhs: BluetoothDeviceModel, rhs: BluetoothDeviceModel) -> Bool {
        return lhs.name == rhs.name &&
               lhs.address == rhs.address &&
               lhs.isConnected == rhs.isConnected
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(address)
        hasher.combine(isConnected)
    }
}

// Visual Effect View wrapper for macOS Glassmorphism
struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// DitherLevel: Defines customizable keep-alive signal intensity
enum DitherLevel: Int, CaseIterable, Identifiable {
    case off = 0
    case low = 1
    case balanced = 3
    case max = 5
    
    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Off (Silent)"
        case .low: return "Low (-100 dB)"
        case .balanced: return "Balanced (-90 dB)"
        case .max: return "Max (-80 dB)"
        }
    }
}

// TelemetryRate: Controls status telemetry and polling frequency
enum TelemetryRate: Double, CaseIterable, Identifiable {
    case fast = 1.0
    case balanced = 2.0
    case saver = 5.0
    
    var id: Double { rawValue }
    var displayName: String {
        switch self {
        case .fast: return "Fast (1.0s)"
        case .balanced: return "Balanced (2.0s)"
        case .saver: return "Saver (5.0s)"
        }
    }
}

// KeepAliveManager: Handles silent loop playback to prevent Bluetooth earbud auto-sleep
class KeepAliveManager: ObservableObject {
    private var audioPlayer: AVAudioPlayer?
    @Published var isRunning = false
    
    func start() {
        guard !isRunning else { return }
        
        let ditherVal = UserDefaults.standard.integer(forKey: "AuraLinkDitherLevel")
        let activeDither = UserDefaults.standard.object(forKey: "AuraLinkDitherLevel") != nil ? ditherVal : 3
        
        if let wavURL = createSilentWAV(ditherLevel: activeDither) {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: wavURL)
                audioPlayer?.numberOfLoops = -1
                audioPlayer?.volume = 0.05 // Faint active volume, combined with faint WAV data
                audioPlayer?.prepareToPlay()
                audioPlayer?.play()
                
                self.isRunning = true
                print("Keep-Alive: Silent/Dithered playback loop started with level: \(activeDither).")
            } catch {
                print("Keep-Alive: AVAudioPlayer error: \(error)")
            }
        }
    }
    
    func stop() {
        guard isRunning else { return }
        audioPlayer?.stop()
        
        self.isRunning = false
        print("Keep-Alive: Silent/Dithered playback loop stopped.")
    }
    
    private func createSilentWAV(ditherLevel: Int) -> URL? {
        let sampleRate: Int32 = 44100
        let channels: Int16 = 2
        let bytesPerSample: Int16 = 2
        let duration: Double = 1.0
        let numSamples = Int32(Double(sampleRate) * duration)
        let dataSize = numSamples * Int32(channels) * Int32(bytesPerSample)
        let fileSize = 36 + dataSize
        
        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        
        let subchunk1Size: Int32 = 16
        header.append(withUnsafeBytes(of: subchunk1Size.littleEndian) { Data($0) })
        
        let audioFormat: Int16 = 1 // PCM
        header.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        
        header.append(withUnsafeBytes(of: channels.littleEndian) { Data($0) })
        
        header.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        
        let byteRate = sampleRate * Int32(channels) * Int32(bytesPerSample)
        header.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        
        let blockAlign = channels * bytesPerSample
        header.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        
        let bitsPerSample = bytesPerSample * 8
        header.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        
        header.append("data".data(using: .ascii)!)
        header.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        
        // Generate randomized 16-bit PCM values (dither) instead of a flat zero-byte array
        var samples = [Int16](repeating: 0, count: Int(numSamples * Int32(channels)))
        let bound = Int16(ditherLevel)
        if bound > 0 {
            for i in 0..<samples.count {
                samples[i] = Int16.random(in: -bound...bound)
            }
        }
        
        let pcmData = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        
        var wavData = header
        wavData.append(pcmData)
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("auralink_silence.wav")
        do {
            try wavData.write(to: fileURL)
            return fileURL
        } catch {
            print("Keep-Alive: WAV write error: \(error)")
            return nil
        }
    }
}

// BluetoothManager: Controls connection monitoring, device lists, RSSI, auto-reconnect, and CoreAudio status
class BluetoothManager: ObservableObject {
    @Published var pairedDevices: [BluetoothDeviceModel] = []
    @Published var activeAudioDeviceName: String? = nil
    @Published var isTargetDeviceConnected: Bool = false
    @Published var targetDeviceRSSI: Int = 0
    @Published var selectedDeviceAddress: String? = nil
    @Published var isAutoReconnectEnabled: Bool = true
    @Published var isKeepAliveEnabled: Bool = true
    
    @Published var isLaunchAtLoginEnabled: Bool = false
    @Published var telemetryInterval: Double = 2.0
    @Published var ditherLevel: Int = 3
    
    var keepAliveManager: KeepAliveManager?
    private var timer: Timer?
    
    init() {
        self.selectedDeviceAddress = UserDefaults.standard.string(forKey: "AuraLinkSelectedDeviceAddress")
        self.isAutoReconnectEnabled = UserDefaults.standard.bool(forKey: "AuraLinkAutoReconnectEnabled")
        if UserDefaults.standard.object(forKey: "AuraLinkAutoReconnectEnabled") == nil {
            self.isAutoReconnectEnabled = true
        }
        
        self.isKeepAliveEnabled = UserDefaults.standard.bool(forKey: "AuraLinkKeepAliveEnabled")
        if UserDefaults.standard.object(forKey: "AuraLinkKeepAliveEnabled") == nil {
            self.isKeepAliveEnabled = true
        }
        
        self.telemetryInterval = UserDefaults.standard.double(forKey: "AuraLinkTelemetryInterval")
        if self.telemetryInterval == 0 {
            self.telemetryInterval = 2.0
        }
        
        self.ditherLevel = UserDefaults.standard.integer(forKey: "AuraLinkDitherLevel")
        if UserDefaults.standard.object(forKey: "AuraLinkDitherLevel") == nil {
            self.ditherLevel = 3 // Balanced
        }
        
        if #available(macOS 13.0, *) {
            self.isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } else {
            self.isLaunchAtLoginEnabled = UserDefaults.standard.bool(forKey: "AuraLinkLaunchAtLoginEnabled")
        }
        
        updateDevices()
        checkActiveAudioDevice()
        updateTimerInterval()
    }
    
    func selectDevice(address: String) {
        self.selectedDeviceAddress = address
        UserDefaults.standard.set(address, forKey: "AuraLinkSelectedDeviceAddress")
        updateDevices()
        checkActiveAudioDevice()
    }
    
    func toggleAutoReconnect() {
        isAutoReconnectEnabled.toggle()
        UserDefaults.standard.set(isAutoReconnectEnabled, forKey: "AuraLinkAutoReconnectEnabled")
    }
    
    func toggleKeepAlive() {
        isKeepAliveEnabled.toggle()
        UserDefaults.standard.set(isKeepAliveEnabled, forKey: "AuraLinkKeepAliveEnabled")
        syncKeepAlive()
    }
    
    func updateTimerInterval() {
        timer?.invalidate()
        let interval = telemetryInterval > 0 ? telemetryInterval : 2.0
        
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.updateDevices()
            self?.checkActiveAudioDevice()
        }
    }
    
    func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    try service.register()
                    print("SMAppService: Successfully registered for launch at login.")
                } else {
                    try service.unregister()
                    print("SMAppService: Successfully unregistered from launch at login.")
                }
                DispatchQueue.main.async {
                    self.isLaunchAtLoginEnabled = enabled
                }
            } catch {
                print("SMAppService registration failed: \(error)")
                DispatchQueue.main.async {
                    self.isLaunchAtLoginEnabled = service.status == .enabled
                }
            }
        } else {
            UserDefaults.standard.set(enabled, forKey: "AuraLinkLaunchAtLoginEnabled")
            DispatchQueue.main.async {
                self.isLaunchAtLoginEnabled = enabled
            }
        }
    }
    
    func setTelemetryInterval(_ interval: Double) {
        UserDefaults.standard.set(interval, forKey: "AuraLinkTelemetryInterval")
        DispatchQueue.main.async {
            self.telemetryInterval = interval
            self.updateTimerInterval()
        }
    }
    
    func setDitherLevel(_ level: Int) {
        UserDefaults.standard.set(level, forKey: "AuraLinkDitherLevel")
        DispatchQueue.main.async {
            self.ditherLevel = level
            if let keepAlive = self.keepAliveManager {
                let wasRunning = keepAlive.isRunning
                if wasRunning {
                    keepAlive.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if self.isKeepAliveEnabled && self.isTargetDeviceConnected {
                            keepAlive.start()
                        }
                    }
                }
            }
        }
    }
    
    func updateDevices() {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        
        var models: [BluetoothDeviceModel] = []
        var targetConnected = false
        var targetRSSI = 0
        
        for device in devices {
            let address = device.addressString ?? ""
            let isConnected = device.isConnected()
            let name = device.name ?? "Unknown Device"
            
            var rssiVal = 0
            if isConnected {
                let rawRssi = Int(device.rawRSSI())
                if rawRssi != 127 {
                    rssiVal = rawRssi
                }
            }
            
            let model = BluetoothDeviceModel(
                name: name,
                address: address,
                isConnected: isConnected,
                rssi: rssiVal
            )
            models.append(model)
            
            if address == selectedDeviceAddress {
                targetConnected = isConnected
                targetRSSI = rssiVal
            }
        }
        
        // Sort alphabetically by name to ensure absolute layout stability
        models.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        
        // Auto-select first paired audio-video device if none selected yet
        if selectedDeviceAddress == nil, let firstDevice = models.first {
            selectedDeviceAddress = firstDevice.address
            UserDefaults.standard.set(firstDevice.address, forKey: "AuraLinkSelectedDeviceAddress")
            targetConnected = firstDevice.isConnected
            targetRSSI = firstDevice.rssi
        }
        
        DispatchQueue.main.async {
            if self.pairedDevices != models {
                self.pairedDevices = models
            }
            if self.isTargetDeviceConnected != targetConnected {
                self.isTargetDeviceConnected = targetConnected
            }
            if self.targetDeviceRSSI != targetRSSI {
                self.targetDeviceRSSI = targetRSSI
            }
            self.syncKeepAlive()
        }
    }
    
    func checkActiveAudioDevice() {
        guard let defaultDeviceID = getDefaultOutputDeviceID() else {
            DispatchQueue.main.async {
                let routeChanged = self.activeAudioDeviceName != "Internal Speakers"
                self.activeAudioDeviceName = "Internal Speakers"
                if routeChanged {
                    print("Audio Route Changed to: Internal Speakers. Force-recycling Keep-Alive.")
                    self.keepAliveManager?.stop()
                }
                self.syncKeepAlive()
            }
            return
        }
        
        let deviceName = getAudioDeviceName(deviceID: defaultDeviceID) ?? "Internal Speakers"
        
        DispatchQueue.main.async {
            let routeChanged = self.activeAudioDeviceName != deviceName
            self.activeAudioDeviceName = deviceName
            
            if routeChanged {
                print("Audio Route Changed to: \(deviceName). Force-recycling Keep-Alive.")
                self.keepAliveManager?.stop()
            }
            
            self.syncKeepAlive()
            
            // Auto reconnect check
            if self.isAutoReconnectEnabled,
               let targetAddress = self.selectedDeviceAddress,
               let targetDevice = self.pairedDevices.first(where: { $0.address == targetAddress }),
               !targetDevice.isConnected {
                print("Auto-Reconnect Daemon: Connecting to \(targetDevice.name)")
                self.connectDevice(address: targetAddress)
            }
        }
    }
    
    private func syncKeepAlive() {
        guard let keepAlive = keepAliveManager else { return }
        
        if isKeepAliveEnabled && isTargetDeviceConnected {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
    }
    
    func connectDevice(address: String) {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        if let device = devices.first(where: { $0.addressString == address }) {
            if !device.isConnected() {
                DispatchQueue.global(qos: .userInitiated).async {
                    device.openConnection()
                }
            }
        }
    }
    
    func disconnectDevice(address: String) {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        if let device = devices.first(where: { $0.addressString == address }) {
            if device.isConnected() {
                DispatchQueue.global(qos: .userInitiated).async {
                    device.closeConnection()
                }
            }
        }
    }
    
    // CoreAudio Helper Methods
    private func getDefaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func getAudioDeviceName(deviceID: AudioDeviceID) -> String? {
        var unmanagedName: Unmanaged<CFString>? = nil
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &unmanagedName
        )
        
        if status == noErr, let name = unmanagedName?.takeRetainedValue() {
            return name as String
        }
        
        var nameBuffer = [CChar](repeating: 0, count: 128)
        propertySize = UInt32(nameBuffer.count)
        address.mSelector = kAudioDevicePropertyDeviceName
        
        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &nameBuffer
        )
        
        if status == noErr {
            return String(cString: nameBuffer)
        }
        
        return nil
    }

    private func isBluetoothDevice(deviceID: AudioDeviceID) -> Bool {
        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &transportType
        )
        
        if status == noErr {
            return transportType == kAudioDeviceTransportTypeBluetooth || transportType == 1651275109
        }
        return false
    }
}

// Custom Glassmorphic Card Wrapper
struct GlassCard<Content: View>: View {
    var content: Content
    
    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.04))
                    .background(VisualEffectView().cornerRadius(12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.12), Color.white.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: Color.black.opacity(0.2), radius: 6, x: 0, y: 3)
    }
}

// HeaderView
struct HeaderView: View {
    @ObservedObject var btManager: BluetoothManager
    @ObservedObject var keepAliveManager: KeepAliveManager
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AURA LINK")
                    .font(.system(size: 13, weight: .black))
                    .tracking(2)
                    .foregroundColor(.white)
                
                HStack(spacing: 4) {
                    Circle()
                        .fill(btManager.isTargetDeviceConnected ? Color(red: 0.0, green: 0.8, blue: 0.6) : .gray)
                        .frame(width: 5, height: 5)
                        .shadow(color: btManager.isTargetDeviceConnected ? Color(red: 0.0, green: 0.8, blue: 0.6).opacity(0.8) : .clear, radius: 3)
                    
                    Text(btManager.isTargetDeviceConnected ? "STABILIZED" : "MONITORING IDLE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(btManager.isTargetDeviceConnected ? Color(red: 0.0, green: 0.8, blue: 0.6) : .white.opacity(0.4))
                }
            }
            
            Spacer()
            
            // Exit App Button
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 9, weight: .bold))
                    Text("Quit")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.65))
                .cornerRadius(6)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Quit AuraLink")
        }
    }
}

// RadarPulseView: Concentric animated rings showing Keep-Alive signal
struct RadarPulseView: View {
    @State private var wave1 = false
    @State private var wave2 = false
    let isPulseActive: Bool
    
    var body: some View {
        ZStack {
            // Wave 1
            Circle()
                .stroke(Color(red: 0.0, green: 0.8, blue: 0.6).opacity(isPulseActive ? 0.6 : 0.0), lineWidth: 1.5)
                .scaleEffect(wave1 ? 1.7 : 0.8)
                .opacity(wave1 ? 0.0 : 1.0)
                .onAppear {
                    withAnimation(Animation.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                        wave1 = true
                    }
                }
            
            // Wave 2
            Circle()
                .stroke(Color(red: 0.0, green: 0.8, blue: 0.6).opacity(isPulseActive ? 0.4 : 0.0), lineWidth: 1.0)
                .scaleEffect(wave2 ? 1.7 : 0.8)
                .opacity(wave2 ? 0.0 : 1.0)
                .onAppear {
                    withAnimation(Animation.linear(duration: 2.0).delay(1.0).repeatForever(autoreverses: false)) {
                        wave2 = true
                    }
                }
            
            // Core
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            isPulseActive ? Color(red: 0.0, green: 0.8, blue: 0.6) : Color.gray,
                            isPulseActive ? Color(red: 0.0, green: 0.5, blue: 0.8) : Color.gray.opacity(0.5)
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: 18
                    )
                )
                .frame(width: 36, height: 36)
                .shadow(color: isPulseActive ? Color(red: 0.0, green: 0.8, blue: 0.6).opacity(0.5) : Color.clear, radius: 8)
            
            Image(systemName: isPulseActive ? "waveform.and.mic" : "waveform.badge.exclamationmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 80, height: 80)
    }
}

// RSSIMonitorView: Displays signal strength decibels and status
struct RSSIMonitorView: View {
    let rssi: Int
    
    var signalStrength: Double {
        if rssi == 0 { return 0 }
        let clamped = min(max(Double(rssi), -100), -40)
        return (clamped + 100) / 60.0 // Normalize to 0.0 - 1.0
    }
    
    var signalColor: Color {
        let pct = signalStrength
        if pct > 0.7 {
            return Color(red: 0.0, green: 0.8, blue: 0.6)
        } else if pct > 0.4 {
            return Color(red: 1.0, green: 0.7, blue: 0.0)
        } else {
            return Color(red: 1.0, green: 0.2, blue: 0.2)
        }
    }
    
    var signalText: String {
        if rssi == 0 { return "Disconnected" }
        let pct = signalStrength
        if pct > 0.7 { return "Excellent (\(rssi) dB)" }
        if pct > 0.4 { return "Good (\(rssi) dB)" }
        return "Weak (\(rssi) dB)"
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("RSSI Telemetry:")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                Text(signalText)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(signalColor)
            }
            
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<5) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < activeBarsCount ? signalColor : Color.white.opacity(0.1))
                        .frame(width: 6, height: CGFloat((index + 1) * 3))
                }
                Spacer()
            }
        }
    }
    
    private var activeBarsCount: Int {
        if rssi == 0 { return 0 }
        let pct = signalStrength
        if pct > 0.8 { return 5 }
        if pct > 0.6 { return 4 }
        if pct > 0.4 { return 3 }
        if pct > 0.2 { return 2 }
        return 1
    }
}

// StatusRadarView
struct StatusRadarView: View {
    @ObservedObject var btManager: BluetoothManager
    @ObservedObject var keepAliveManager: KeepAliveManager
    
    var body: some View {
        GlassCard {
            HStack(spacing: 12) {
                RadarPulseView(isPulseActive: keepAliveManager.isRunning)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedDeviceName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    
                    Text(connectionStatusText)
                        .font(.system(size: 10))
                        .foregroundColor(btManager.isTargetDeviceConnected ? .green : .white.opacity(0.4))
                    
                    RSSIMonitorView(rssi: btManager.isTargetDeviceConnected ? btManager.targetDeviceRSSI : 0)
                }
                Spacer()
            }
        }
    }
    
    private var selectedDeviceName: String {
        if let address = btManager.selectedDeviceAddress,
           let device = btManager.pairedDevices.first(where: { $0.address == address }) {
            return device.name
        }
        return "No Target Device"
    }
    
    private var connectionStatusText: String {
        if btManager.isTargetDeviceConnected {
            return keepAliveManager.isRunning ? "Active Stabilization Loop" : "Connected (Idle)"
        }
        return "Disconnected"
    }
}

// ToggleRow
struct ToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            Spacer()
            
            Toggle("", isOn: $isOn)
                .toggleStyle(SwitchToggleStyle(tint: iconColor))
        }
    }
}

// ControlsView
struct ControlsView: View {
    @ObservedObject var btManager: BluetoothManager
    @ObservedObject var keepAliveManager: KeepAliveManager
    
    var body: some View {
        GlassCard {
            VStack(spacing: 10) {
                ToggleRow(
                    icon: "waveform.path",
                    iconColor: Color(red: 0.0, green: 0.8, blue: 0.6),
                    title: "Active Keep-Alive",
                    subtitle: "Sends tiny pings to prevent sleep state",
                    isOn: Binding(
                        get: { btManager.isKeepAliveEnabled },
                        set: { _ in btManager.toggleKeepAlive() }
                    )
                )
                
                Divider()
                    .background(Color.white.opacity(0.08))
                
                ToggleRow(
                    icon: "arrow.3.trianglepath",
                    iconColor: Color(red: 0.0, green: 0.5, blue: 0.8),
                    title: "Auto-Reconnect Daemon",
                    subtitle: "Background reconnect if link drops",
                    isOn: Binding(
                        get: { btManager.isAutoReconnectEnabled },
                        set: { _ in btManager.toggleAutoReconnect() }
                    )
                )
            }
        }
    }
}

// DeviceRowView
struct DeviceRowView: View {
    let device: BluetoothDeviceModel
    @ObservedObject var btManager: BluetoothManager
    
    var isSelected: Bool {
        device.address == btManager.selectedDeviceAddress
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(isSelected ? Color(red: 0.0, green: 0.8, blue: 0.6) : .white)
                    .lineLimit(1)
                
                Text(device.isConnected ? "Connected" : "Disconnected")
                    .font(.system(size: 9))
                    .foregroundColor(device.isConnected ? .green : .white.opacity(0.3))
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.0, green: 0.8, blue: 0.6))
                    .padding(.trailing, 6)
            }
            
            Button(action: {
                if device.isConnected {
                    btManager.disconnectDevice(address: device.address)
                } else {
                    btManager.connectDevice(address: device.address)
                }
            }) {
                Text(device.isConnected ? "Disconnect" : "Connect")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(device.isConnected ? Color.red.opacity(0.2) : Color.white.opacity(0.08))
                    .foregroundColor(device.isConnected ? .red : .white)
                    .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.white.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            btManager.selectDevice(address: device.address)
        }
    }
}

// DevicesListView
struct DevicesListView: View {
    @ObservedObject var btManager: BluetoothManager
    
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Select stabilized target device:")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.5))
                
                ScrollView {
                    VStack(spacing: 4) {
                        if btManager.pairedDevices.isEmpty {
                            Text("No paired Bluetooth audio devices.")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.vertical, 10)
                        } else {
                            ForEach(btManager.pairedDevices) { device in
                                DeviceRowView(device: device, btManager: btManager)
                            }
                        }
                    }
                }
                .frame(maxHeight: 100)
            }
        }
    }
}

// DiagnosticsView
struct DiagnosticsView: View {
    @Binding var showingDiagnostics: Bool
    @ObservedObject var btManager: BluetoothManager
    
    @State private var resetStatus = ""
    
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    withAnimation {
                        showingDiagnostics.toggle()
                    }
                }) {
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundColor(Color(red: 0.0, green: 0.8, blue: 0.6))
                        Text("System Recovery Diagnostics")
                            .font(.system(size: 11, weight: .bold))
                        Spacer()
                        Image(systemName: showingDiagnostics ? "chevron.up" : "chevron.down")
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                if showingDiagnostics {
                    VStack(spacing: 6) {
                        Text("Triggers native administrator authorization prompts to restart system engines if sound gets muted or connection drops severely:")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.bottom, 2)
                        
                        HStack(spacing: 8) {
                            Button(action: triggerCoreAudioReset) {
                                HStack {
                                    Image(systemName: "waveform.path.badge.minus")
                                    Text("Reset Audio")
                                }
                                .font(.system(size: 9, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color(red: 1.0, green: 0.4, blue: 0.0).opacity(0.15))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(red: 1.0, green: 0.4, blue: 0.0).opacity(0.25), lineWidth: 1)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                            
                            Button(action: triggerBluetoothReset) {
                                HStack {
                                    Image(systemName: "bolt.horizontal.fill")
                                    Text("Reset Bluetoothd")
                                }
                                .font(.system(size: 9, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color(red: 1.0, green: 0.2, blue: 0.2).opacity(0.15))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(red: 1.0, green: 0.2, blue: 0.2).opacity(0.25), lineWidth: 1)
                                )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        if !resetStatus.isEmpty {
                            Text(resetStatus)
                                .font(.system(size: 9))
                                .foregroundColor(Color(red: 0.0, green: 0.8, blue: 0.6))
                                .padding(.top, 2)
                                .transition(.opacity)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
    
    private func triggerCoreAudioReset() {
        resetStatus = "Awaiting system auth..."
        DispatchQueue.global(qos: .userInitiated).async {
            let script = "do shell script \"killall coreaudiod\" with administrator privileges"
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            
            DispatchQueue.main.async {
                if let err = error {
                    self.resetStatus = "Auth Denied or Failed"
                    print("CoreAudio restart failed: \(err)")
                } else {
                    self.resetStatus = "Audio daemon successfully restarted!"
                    self.btManager.checkActiveAudioDevice()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.resetStatus == "Audio daemon successfully restarted!" || self.resetStatus == "Auth Denied or Failed" {
                        self.resetStatus = ""
                    }
                }
            }
        }
    }
    
    private func triggerBluetoothReset() {
        resetStatus = "Awaiting system auth..."
        DispatchQueue.global(qos: .userInitiated).async {
            let script = "do shell script \"pkill bluetoothd\" with administrator privileges"
            let appleScript = NSAppleScript(source: script)
            var error: NSDictionary?
            appleScript?.executeAndReturnError(&error)
            
            DispatchQueue.main.async {
                if let err = error {
                    self.resetStatus = "Auth Denied or Failed"
                    print("Bluetooth restart failed: \(err)")
                } else {
                    self.resetStatus = "Bluetooth daemon successfully restarted!"
                    self.btManager.updateDevices()
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    if self.resetStatus == "Bluetooth daemon successfully restarted!" || self.resetStatus == "Auth Denied or Failed" {
                        self.resetStatus = ""
                    }
                }
            }
        }
    }
}

// AdvancedSettingsView: Interactive card for advanced configurations
struct AdvancedSettingsView: View {
    @Binding var showingSettings: Bool
    @ObservedObject var btManager: BluetoothManager
    @ObservedObject var keepAliveManager: KeepAliveManager
    
    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: {
                    withAnimation {
                        showingSettings.toggle()
                    }
                }) {
                    HStack {
                        Image(systemName: "gearshape.fill")
                            .foregroundColor(Color(red: 0.0, green: 0.8, blue: 0.6))
                        Text("Advanced Configuration")
                            .font(.system(size: 11, weight: .bold))
                        Spacer()
                        Image(systemName: showingSettings ? "chevron.up" : "chevron.down")
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                if showingSettings {
                    VStack(spacing: 8) {
                        // Launch at Login Toggle
                        ToggleRow(
                            icon: "sidebar.left",
                            iconColor: Color(red: 0.0, green: 0.8, blue: 0.6),
                            title: "Launch at Login",
                            subtitle: "Start AuraLink automatically at boot",
                            isOn: Binding(
                                get: { btManager.isLaunchAtLoginEnabled },
                                set: { newValue in btManager.setLaunchAtLogin(newValue) }
                            )
                        )
                        
                        Divider()
                            .background(Color.white.opacity(0.08))
                        
                        // Telemetry Interval Picker
                        HStack {
                            Image(systemName: "timer")
                                .font(.system(size: 14))
                                .foregroundColor(Color(red: 0.0, green: 0.5, blue: 0.8))
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Telemetry Rate")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Frequency of status updates")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { btManager.telemetryInterval },
                                set: { newValue in btManager.setTelemetryInterval(newValue) }
                            )) {
                                ForEach(TelemetryRate.allCases) { rate in
                                    Text(rate.displayName).tag(rate.rawValue)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                        }
                        
                        Divider()
                            .background(Color.white.opacity(0.08))
                        
                        // Dither Level Picker
                        HStack {
                            Image(systemName: "waveform")
                                .font(.system(size: 14))
                                .foregroundColor(Color(red: 0.0, green: 0.8, blue: 0.6))
                                .frame(width: 20)
                            
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Stabilizer Strength")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Audio dither signal intensity")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            
                            Spacer()
                            
                            Picker("", selection: Binding(
                                get: { btManager.ditherLevel },
                                set: { newValue in btManager.setDitherLevel(newValue) }
                            )) {
                                ForEach(DitherLevel.allCases) { dither in
                                    Text(dither.displayName).tag(dither.rawValue)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                        }
                    }
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
}

// Main AuraLinkView Popover Frame
struct AuraLinkView: View {
    @ObservedObject var btManager: BluetoothManager
    @ObservedObject var keepAliveManager: KeepAliveManager
    
    @State private var showingDiagnostics = false
    @State private var showingSettings = false
    
    var body: some View {
        VStack(spacing: 8) {
            HeaderView(btManager: btManager, keepAliveManager: keepAliveManager)
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    StatusRadarView(btManager: btManager, keepAliveManager: keepAliveManager)
                    
                    ControlsView(btManager: btManager, keepAliveManager: keepAliveManager)
                    
                    DevicesListView(btManager: btManager)
                    
                    AdvancedSettingsView(showingSettings: $showingSettings, btManager: btManager, keepAliveManager: keepAliveManager)
                    
                    DiagnosticsView(showingDiagnostics: $showingDiagnostics, btManager: btManager)
                }
            }
            
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Spacer()
                    Image(systemName: "power.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Quit AuraLink")
                        .font(.system(size: 10, weight: .bold))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 2)
            
            HStack {
                Text("Audio Target: \(btManager.activeAudioDeviceName ?? "Searching...")")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                Spacer()
                Text("v1.0")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.3))
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 320, height: 550)
        .background(
            ZStack {
                Color(red: 0.07, green: 0.08, blue: 0.11)
                
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.0, green: 0.5, blue: 0.8).opacity(0.12),
                        Color.clear
                    ]),
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 180
                )
                
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.0, green: 0.8, blue: 0.6).opacity(0.08),
                        Color.clear
                    ]),
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: 180
                )
            }
        )
        .foregroundColor(.white)
    }
}

// App Delegate using NSPopover to avoid the SwiftUI MenuBarExtra dynamic sizing bug
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    let popover = NSPopover()
    let btManager = BluetoothManager()
    let keepAliveManager = KeepAliveManager()
    private var cancellables = Set<AnyCancellable>()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hides app from the dock so it resides entirely in the Menu Bar
        NSApp.setActivationPolicy(.accessory)
        
        // Link managers
        btManager.keepAliveManager = keepAliveManager
        btManager.updateDevices()
        
        // Wrap SwiftUI View inside NSHostingController
        let contentView = AuraLinkView(btManager: btManager, keepAliveManager: keepAliveManager)
        popover.contentViewController = NSHostingController(rootView: contentView)
        popover.contentSize = NSSize(width: 320, height: 550)
        popover.behavior = .transient
        
        // Create Status Bar Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        
        // Dynamic status bar icon using Combine subscription
        btManager.$isTargetDeviceConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnected in
                self?.updateMenuBarIcon(isConnected: isConnected)
            }
            .store(in: &cancellables)
    }
    
    func updateMenuBarIcon(isConnected: Bool) {
        guard let button = statusItem?.button else { return }
        
        let imageName = isConnected ? "wave.3.right.circle.fill" : "wave.3.right.circle"
        
        if #available(macOS 13.0, *) {
            button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: "AuraLink")
        } else {
            button.image = NSImage(named: NSImage.Name(imageName))
        }
        
        // Use neon green tint color when active/stabilized
        if isConnected {
            button.contentTintColor = NSColor(red: 0.0, green: 0.8, blue: 0.6, alpha: 1.0)
        } else {
            button.contentTintColor = nil
        }
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                popover.contentSize = NSSize(width: 320, height: 550)
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                
                // Bring window to front
                if let window = popover.contentViewController?.view.window {
                    window.makeKey()
                }
            }
        }
    }
}

// App Entry Point
@main
struct AuraLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
