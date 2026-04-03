// amber-tint.swift
// Full-screen amber color filter for macOS.
// Uses CoreGraphics gamma tables to tint all displays warm amber —
// the same technique f.lux uses. No overlay windows, no private APIs.

import SwiftUI
import CoreGraphics

// MARK: - Gamma Engine

/// Applies amber tint by clamping RGB channel maximums via CGSetDisplayTransferByFormula.
/// Red stays at 1.0, green and blue are reduced aggressively to create deep warm amber.
/// At full intensity: green at 50%, blue at 10% — deep firelight (~1500K).
enum GammaEngine {

    /// Apply amber tint to a single display.
    /// - Parameters:
    ///   - display: The CGDirectDisplayID to tint.
    ///   - intensity: 0.0 (no tint) to 1.0 (deep amber ~1800K).
    static func apply(to display: CGDirectDisplayID, intensity: Double) {
        let redMax: CGGammaValue   = 1.0
        let greenMax: CGGammaValue = Float(1.0 - intensity * 0.50)
        let blueMax: CGGammaValue  = Float(1.0 - intensity * 0.90)

        CGSetDisplayTransferByFormula(
            display,
            0, redMax, 1.0,    // red:   min=0, max=1.0, gamma=1.0 (linear)
            0, greenMax, 1.0,  // green: min=0, max=clamped, gamma=1.0
            0, blueMax, 1.0    // blue:  min=0, max=clamped, gamma=1.0
        )
    }

    /// Apply amber tint to all active displays.
    static func applyToAll(intensity: Double) {
        for display in activeDisplays() {
            apply(to: display, intensity: intensity)
        }
    }

    /// Restore all displays to their ColorSync defaults.
    static func restore() {
        CGDisplayRestoreColorSyncSettings()
    }

    /// Get all currently active display IDs.
    static func activeDisplays() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        return displays
    }
}

// MARK: - Display Watcher

/// Watches for display connect/disconnect/reconfigure events and re-applies gamma.
/// Uses CGDisplayRegisterReconfigurationCallback with Unmanaged pointer passing
/// and a 1-second debounce timer (displays need initialization time).
class DisplayWatcher {
    private var timer: Timer?
    private var onReconfigure: (() -> Void)?

    init(onReconfigure: @escaping () -> Void) {
        self.onReconfigure = onReconfigure
    }

    static let callback: CGDisplayReconfigurationCallBack = { (_, flags, userInfo) in
        guard let opaque = userInfo else { return }
        let watcher = Unmanaged<DisplayWatcher>.fromOpaque(opaque).takeUnretainedValue()

        if flags.contains(.addFlag) || flags.contains(.removeFlag) ||
           flags.contains(.enabledFlag) || flags.contains(.disabledFlag) {
            DispatchQueue.main.async {
                if watcher.timer?.isValid != true {
                    watcher.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                        watcher.onReconfigure?()
                    }
                }
            }
        }
    }

    func start() {
        let userData = Unmanaged<DisplayWatcher>.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(DisplayWatcher.callback, userData)
    }

    func stop() {
        let userData = Unmanaged<DisplayWatcher>.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(DisplayWatcher.callback, userData)
        timer?.invalidate()
    }
}

// MARK: - Amber State

/// Observable state holding tint enabled/disabled and intensity.
/// Persists to UserDefaults. Every mutation re-applies gamma to all displays.
@Observable
class AmberState {
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "amberEnabled")
            applyCurrentState()
        }
    }

    var intensity: Double {
        didSet {
            UserDefaults.standard.set(intensity, forKey: "amberIntensity")
            if isEnabled { applyCurrentState() }
        }
    }

    init() {
        // Load persisted state, defaulting to enabled at 50% intensity
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "amberEnabled") != nil {
            self.isEnabled = defaults.bool(forKey: "amberEnabled")
        } else {
            self.isEnabled = true
        }
        let saved = defaults.double(forKey: "amberIntensity")
        self.intensity = saved > 0 ? saved : 0.5
    }

    func applyCurrentState() {
        if isEnabled {
            GammaEngine.applyToAll(intensity: intensity)
        } else {
            GammaEngine.restore()
        }
    }
}

// MARK: - Menu View

/// SwiftUI menu bar popover: toggle, intensity slider, quit.
struct AmberMenuView: View {
    @Bindable var state: AmberState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Amber Tint", isOn: $state.isEnabled)
                .toggleStyle(.switch)

            if state.isEnabled {
                HStack {
                    Image(systemName: "sun.min")
                        .foregroundStyle(.secondary)
                    Slider(value: $state.intensity, in: 0.1...1.0, step: 0.05)
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.orange)
                }

                Text(intensityLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit Amber Tint") {
                GammaEngine.restore()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 220)
    }

    private var intensityLabel: String {
        let pct = Int(state.intensity * 100)
        // Rough color temperature mapping for display
        let temp: String
        switch state.intensity {
        case 0.0..<0.3:  temp = "~3500K"
        case 0.3..<0.6:  temp = "~2700K"
        case 0.6..<0.85: temp = "~1800K"
        default:          temp = "~1500K"
        }
        return "\(pct)% · \(temp)"
    }
}

// MARK: - App Delegate

/// Handles lifecycle: restore gamma on quit, re-apply on wake from sleep.
class AmberAppDelegate: NSObject, NSApplicationDelegate {
    var state: AmberState?
    var displayWatcher: DisplayWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-apply after wake — macOS resets gamma tables on sleep/wake
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        GammaEngine.restore()
        displayWatcher?.stop()
    }

    @objc private func handleWake() {
        // 1-second delay: display needs initialization time after wake
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.state?.applyCurrentState()
        }
    }
}

// MARK: - App Entry Point

@main
struct AmberTintApp: App {
    @NSApplicationDelegateAdaptor(AmberAppDelegate.self) var delegate

    @State private var state = AmberState()
    @State private var watcher: DisplayWatcher?

    var body: some Scene {
        MenuBarExtra(
            "Amber Tint",
            systemImage: state.isEnabled ? "sun.max.fill" : "sun.min"
        ) {
            AmberMenuView(state: state)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: state.isEnabled) { _, _ in }
        .defaultSize(width: 220, height: 160)
    }

    init() {
        // Apply initial state on launch
        let initialState = AmberState()

        // Wire up display watcher for hotplug
        let watcher = DisplayWatcher {
            initialState.applyCurrentState()
        }
        watcher.start()

        // Store references for lifecycle management
        _state = State(initialValue: initialState)
        _watcher = State(initialValue: watcher)

        // Wire delegate references
        DispatchQueue.main.async {
            if let del = NSApplication.shared.delegate as? AmberAppDelegate {
                del.state = initialState
                del.displayWatcher = watcher
            }
        }

        // Apply on launch
        initialState.applyCurrentState()
    }
}
