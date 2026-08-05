#if canImport(AppKit)
import AppKit
import CoreAudio
import IOKit.ps

/// What the machine feels like right now.
///
/// **Every signal here is permission-free, and most are structurally incapable of capturing
/// content.** He can feel your typing *rhythm* through a counter that reports a number and
/// cannot report a key. He can tell the microphone is live without listening to it. That is
/// a design constraint, not an afterthought: if a signal needs a prompt, it does not ship.
public struct Sensations: Sendable {
    public var idleSeconds: Double = 0
    public var typingRate: Double = 0        // keystrokes per minute
    public var micLive = false
    public var batteryPercent: Int? = nil
    public var charging = false
    public var lowPower = false
    public var asleep = false                // screen locked or display asleep
    /// The user has told the OS that things moving on screen hurt. No panel, no toggle:
    /// he reads the room through the accessibility setting that already exists.
    public var reduceMotion = false

    /// He conserves energy when the machine is. Manifesto: a sluggish cat means plug in.
    /// Reduce Motion pins the same dial: a permanently calm cat, through the mechanism the
    /// battery already tunes, rather than a second way of being slow.
    public var languor: Double {
        if lowPower || reduceMotion { return 1 }
        guard let b = batteryPercent, !charging, b < 20 else { return 0 }
        return min(1, Double(20 - b) / 15)
    }
}

@MainActor
public final class Signals {

    private var lastKeyCount = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
    private var lastKeySample = CACurrentMediaTime()
    private var smoothedRate: Double = 0

    private var micLive = false
    private var lastMicPoll: CFTimeInterval = 0

    private var battery: (percent: Int, charging: Bool)?
    private var lastPowerPoll: CFTimeInterval = 0

    public private(set) var screenAsleep = false
    /// Fired when the machine comes back. Load-bearing: once the display link is paused it
    /// stops calling us, so nothing inside the tick loop can ever notice the wake.
    public var onWake: (() -> Void)?

    public init() {
        let dnc = DistributedNotificationCenter.default()
        // Undocumented but stable since ~10.6, and registering by explicit name works even
        // under sandbox. Paired with a state read at launch, because a notification missed
        // while not running is gone forever.
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenAsleep = true }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenAsleep = false; self?.onWake?() }
        }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenAsleep = true }
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenAsleep = false; self?.onWake?() }
        }
        screenAsleep = Self.isLockedNow()

        // Power events arrive as a notification rather than waiting for the battery poll:
        // the 30s cadence is fine for a percentage and terrible for the plug-in stretch,
        // which Hamzah tested by connecting the charger and watching nothing happen. The
        // callback just invalidates the poll clock, so the next sample re-reads at once.
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let signals = Unmanaged<Signals>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { signals.lastPowerPoll = 0 }
            }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    /// Sampled from inside the display link. No timers, no listeners, no lifecycles.
    public func sample(now: CFTimeInterval) -> Sensations {
        var s = Sensations()
        s.idleSeconds = CGEventSource.secondsSinceLastEventType(
            .hidSystemState, eventType: CGEventType(rawValue: ~0)!)

        // Aggregate keystroke COUNT. Apple documents this exact use case ("prompt a typist
        // to take a break"). It is a statistic, not an event, so there is nothing for
        // Accessibility or Input Monitoring to gate and nothing that could reveal a key.
        let count = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
        let dt = now - lastKeySample
        if dt > 0.25 {
            let delta = Double(count &- lastKeyCount)   // wrap-safe: the counter is a UInt32
            let instant = delta / dt * 60
            smoothedRate += (instant - smoothedRate) * 0.35
            lastKeyCount = count
            lastKeySample = now
        }
        s.typingRate = smoothedRate

        // 4Hz is plenty for a cat noticing something, and polling removes an entire
        // listener lifecycle.
        if now - lastMicPoll > 0.25 { micLive = Self.micRunning(); lastMicPoll = now }
        s.micLive = micLive

        if now - lastPowerPoll > 30 { battery = Self.power(); lastPowerPoll = now }
        s.batteryPercent = battery?.percent
        s.charging = battery?.charging ?? false
        s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        s.asleep = screenAsleep
        return s
    }

    // MARK: - Permission-free machine reads

    /// Is anything using the microphone?
    ///
    /// Uses the macOS 14.4+ per-**process** API rather than the per-device property.
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` always reports false for Bluetooth
    /// microphones — an unresolved Apple bug — which would silently break this for every
    /// AirPods user, and AirPods are how a large share of people take calls.
    /// Falls back to the device property if the process list is unavailable.
    static func micRunning() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                          &addr, 0, nil, &size) == noErr, size > 0 {
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                          &addr, 0, nil, &size, &ids) == noErr {
                for id in ids where processIsRunningInput(id) { return true }
                return false
            }
        }
        return deviceRunningSomewhere()
    }

    private static func processIsRunningInput(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func deviceRunningSomewhere() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &device) == noErr else { return false }
        var running = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var vsize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &running, 0, nil, &vsize, &value) == noErr else { return false }
        return value != 0
    }

    static func power() -> (percent: Int, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return (cur * 100 / max, d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil   // desktop Macs have no battery
    }

    /// Ground truth at launch, since a lock notification that fired while we were not
    /// running is gone forever.
    static func isLockedNow() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // The key is PRESENT only while locked; it is absent when unlocked, not 0.
        return d["CGSSessionScreenIsLocked"] != nil
    }
}
#endif
