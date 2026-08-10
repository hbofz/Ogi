#if canImport(AppKit)
import AppKit
import CoreAudio
import CoreMediaIO
import IOKit
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
    /// The camera is running. Permission-free, and it reports *that* a device is on and
    /// nothing about what it sees — the same shape of read as `micLive`.
    ///
    /// The camera lives in the notch, which is his house, so this is the one signal that can
    /// evict him from it.
    public var cameraLive = false
    public var batteryPercent: Int? = nil
    public var charging = false
    public var lowPower = false
    public var asleep = false                // screen locked or display asleep
    /// The user has told the OS that things moving on screen hurt. No panel, no toggle:
    /// he reads the room through the accessibility setting that already exists.
    public var reduceMotion = false
    /// One-shots, true on the sample after the event and never again: an audio device
    /// arrived (AirPods in his ears), or something plugged into a USB port (a phone).
    public var audioArrived = false
    public var usbArrived = false

    /// He conserves energy when the machine is. A sluggish cat means plug in.
    /// Reduce Motion pins the same dial: a permanently calm cat, through the mechanism the
    /// battery already tunes, rather than a second way of being slow.
    public var languor: Double {
        if lowPower || reduceMotion { return 1 }
        guard let b = batteryPercent, !charging, b < 20 else { return 0 }
        return min(1, Double(20 - b) / 15)
    }
}

/// A boolean that has to mean it.
///
/// **Slow to arm, instant to clear.** Both of Ogi's "is a device live" reads are true the
/// instant *any* process opens the stream, and on a real Mac that includes things which are not
/// a call: `corespeechd`, the always-on "Hey Siri" listener, takes the microphone in bursts
/// shorter than a second. Unsettled, that blip puts a headset on a cat with nobody on the other
/// end of the line.
///
/// The asymmetry is the design. Arming late costs a second and a half of a privacy tell that
/// macOS's own orange dot has already given you; clearing late would leave him wearing the rig
/// after your call ended, which is the failure that actually reads as broken.
struct Settling {
    private var since: CFTimeInterval?
    private(set) var value = false

    mutating func update(_ raw: Bool, now: CFTimeInterval, settle: Double) -> Bool {
        guard raw else {
            since = nil
            value = false
            return false
        }
        let start = since ?? now
        since = start
        value = now - start >= settle
        return value
    }
}

@MainActor
public final class Signals {

    private var lastKeyCount = CGEventSource.counterForEventType(.hidSystemState, eventType: .keyDown)
    private var lastKeySample = CACurrentMediaTime()
    private var smoothedRate: Double = 0

    private var mic = Settling()
    private var camera = Settling()
    private var lastMicPoll: CFTimeInterval = 0

    private var battery: (percent: Int, charging: Bool)?
    private var lastPowerPoll: CFTimeInterval = 0

    private var audioDeviceCount = -1
    private var audioArrived = false
    private var usbArrived = false
    private var usbPort: IONotificationPortRef?
    private var usbIterator: io_iterator_t = 0

    public private(set) var screenAsleep = false
    /// Fired when the machine comes back. Load-bearing: once the display link is paused it
    /// stops ticking, so nothing inside the tick loop can ever notice the wake.
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

        // New ears. The device LIST is watched rather than any stream: connecting AirPods
        // changes which devices exist, which is a count, and a count cannot carry a sound.
        // Only additions count — devices leaving are not an arrival.
        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &devicesAddr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let n = Self.audioDeviceTally()
                if n > self.audioDeviceCount, self.audioDeviceCount >= 0 {
                    self.audioArrived = true
                }
                self.audioDeviceCount = n
            }
        }
        audioDeviceCount = Self.audioDeviceTally()

        // Something on the cable. IOKit announces USB devices as they match; the iterator
        // is drained once at setup so the devices already present are not "arrivals", and
        // drained again on each callback because an undrained iterator never fires again.
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
            let usbCtx = Unmanaged.passUnretained(self).toOpaque()
            var iterator: io_iterator_t = 0
            let matched = IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"),
                { context, iterator in
                    guard let context else { return }
                    var arrived = false
                    while case let device = IOIteratorNext(iterator), device != 0 {
                        IOObjectRelease(device)
                        arrived = true
                    }
                    guard arrived else { return }
                    let signals = Unmanaged<Signals>.fromOpaque(context).takeUnretainedValue()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { signals.usbArrived = true }
                    }
                }, usbCtx, &iterator)
            if matched == KERN_SUCCESS {
                while case let device = IOIteratorNext(iterator), device != 0 {
                    IOObjectRelease(device)
                }
                usbPort = port
                usbIterator = iterator
            } else {
                IONotificationPortDestroy(port)
            }
        }

        // Power events arrive as a notification rather than waiting for the battery poll:
        // a slow cadence is fine for a percentage and terrible for the plug-in stretch. The
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
        if now - lastMicPoll > 0.25 {
            _ = mic.update(Self.micRunning(), now: now, settle: Feel.Mind.deviceSettleSeconds)
            _ = camera.update(Self.cameraRunning(), now: now, settle: Feel.Mind.deviceSettleSeconds)
            lastMicPoll = now
        }
        s.micLive = mic.value
        s.cameraLive = camera.value

        // 2s, belt AND braces: the IOPS notification should make the re-read instant, but
        // reading the power sources costs microseconds, so at 0.5Hz it is nothing, and it
        // caps the zap's worst-case lag at two seconds even if the notification never fires
        // at all.
        if now - lastPowerPoll > 2 { battery = Self.power(); lastPowerPoll = now }
        s.batteryPercent = battery?.percent
        s.charging = battery?.charging ?? false
        s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        s.asleep = screenAsleep
        // One-shots: handed over exactly once.
        s.audioArrived = audioArrived
        s.usbArrived = usbArrived
        audioArrived = false
        usbArrived = false
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
                for id in ids where processIsRunningInput(id) && !isAlwaysListening(id) {
                    return true
                }
                return false
            }
        }
        return deviceRunningSomewhere()
    }

    /// Is anything using the camera?
    ///
    /// The same question the green privacy LED answers, asked of CoreMediaIO: enumerate the
    /// video devices and ask each whether it is running somewhere. **No permission**, and
    /// structurally incapable of capturing an image — it returns a flag per device and there is
    /// no path from here to a frame. It is one of the permission-free reads.
    ///
    /// Unlike the microphone there is no per-*process* CoreMediaIO property, so the device
    /// property is the only read available. That is the same family of property that misreports
    /// for Bluetooth microphones, but a camera is not a Bluetooth audio device and is not
    /// affected. **Still wants confirming against the LED on real hardware.**
    static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),
                                            &addr, 0, nil, &size) == noErr, size > 0
        else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                        &addr, 0, nil, size, &used, &ids) == noErr
        else { return false }
        for id in ids where deviceIsRunningSomewhere(id) { return true }
        return false
    }

    private static func deviceIsRunningSomewhere(_ id: CMIOObjectID) -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(id, &addr, 0, nil,
                                        UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr
        else { return false }
        return value != 0
    }

    /// Daemons that hold the microphone open as a matter of course, and whose doing so does not
    /// mean anybody is listening to you.
    ///
    /// **Measured, not guessed.** `com.apple.CoreSpeech` — the "Hey Siri" listener, on by
    /// default — reports a running input *continuously*, while
    /// `kAudioDevicePropertyDeviceIsRunningSomewhere` reports the microphone idle at the same
    /// instant. Without this filter the per-process read is true forever on any Mac with Siri
    /// enabled, which is a cat wearing a headset all day.
    ///
    /// **The obvious alternative is worse.** The device property gets this case right, but it
    /// always reports false for Bluetooth microphones — an Apple bug — which would silently
    /// break the signal for everyone who takes calls on AirPods. That trades a false positive
    /// for a false negative on the commonest calling setup. So: keep the per-process read, name
    /// the daemon.
    ///
    /// Deliberately not "anything from Apple". `com.apple.FaceTime` is a call.
    static let alwaysListening: Set<String> = ["com.apple.CoreSpeech"]

    private static func isAlwaysListening(_ id: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cf: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr,
              let bundle = cf as String? else { return false }
        return alwaysListening.contains(bundle)
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

    /// How many audio devices exist right now. Which ones is nobody's business.
    private static func audioDeviceTally() -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    static func power() -> (percent: Int, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            // "On AC", not kIOPSIsChargingKey: a full battery reports IsCharging=false with
            // the cable in (battery care too), so the plug-in stretch never fired on a
            // topped-up MacBook. Power present is also the right sense for languor: a
            // plugged-in Mac at 19% that happens not to be charging is not a Mac he should
            // be conserving for.
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cur * 100 / max, onAC)
        }
        return nil   // desktop Macs have no battery
    }

    /// Ground truth at launch, since a lock notification that fired before the app was
    /// running is gone forever.
    static func isLockedNow() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // The key is PRESENT only while locked; it is absent when unlocked, not 0.
        return d["CGSSessionScreenIsLocked"] != nil
    }
}
#endif
