import Testing
import CoreGraphics
@testable import OgiCore

private func run(_ g: inout Gaze, target: CGPoint, seconds: CGFloat, dt: CGFloat = 1.0 / 120) {
    var t: CGFloat = 0
    while t < seconds { g.step(target: target, dt: dt); t += dt }
}

@Test func eyesHoldStillDuringTheLatencyBeforeMoving() {
    // The 80ms lag is a delay before the jump, not smoothing. If this fails
    // the eyes are gliding, which is the single thing that makes a character read as software.
    var g = Gaze()
    run(&g, target: CGPoint(x: 1, y: 0), seconds: Feel.Eyes.latency * 0.6)
    #expect(hypot(g.offset.x, g.offset.y) < 0.001, "eyes started moving before the latency elapsed")
}

@Test func eyesReachTheTargetAfterTheSaccade() {
    var g = Gaze()
    run(&g, target: CGPoint(x: 1, y: 0), seconds: 0.4)
    #expect(abs(g.offset.x - 1) < 0.02)
    #expect(abs(g.offset.y) < 0.02)
}

@Test func saccadeDoesNotOvershoot() {
    // Real saccades have no bounce. A spring would overshoot and read as cartoonish.
    var g = Gaze()
    var peak: CGFloat = 0
    var t: CGFloat = 0
    while t < 0.4 {
        g.step(target: CGPoint(x: 1, y: 0), dt: 1.0 / 240)
        peak = max(peak, g.offset.x)
        t += 1.0 / 240
    }
    #expect(peak <= 1.001, "the saccade overshot its target")
}

@Test func tinyCursorDriftDoesNotMoveTheEyes() {
    // Below the threshold he simply holds. Otherwise he twitches constantly.
    var g = Gaze()
    run(&g, target: CGPoint(x: 0.03, y: 0), seconds: 0.5)
    #expect(hypot(g.offset.x, g.offset.y) < 0.001)
}

@Test func heEventuallyMakesAMicroSaccadeWhenNothingChanges() {
    // Real eyes never hold perfectly still for a full second.
    var g = Gaze()
    run(&g, target: CGPoint(x: 0.10, y: 0), seconds: 0.5)
    #expect(hypot(g.offset.x, g.offset.y) < 0.001, "moved too early")
    run(&g, target: CGPoint(x: 0.10, y: 0), seconds: 1.2)
    #expect(g.offset.x > 0.05, "never made an involuntary micro-saccade")
}

@Test func blinkClosesAndFullyReopens() {
    var g = Gaze()
    var minLid: CGFloat = 1
    var t: CGFloat = 0
    // Blinks are Poisson with a 4s mean, so 60s is statistically certain.
    while t < 60 {
        g.step(target: .zero, dt: 1.0 / 120)
        minLid = min(minLid, g.lid)
        t += 1.0 / 120
    }
    #expect(minLid <= Feel.Eyes.lidFloor + 0.01, "never blinked")
    #expect(minLid > 0, "closed to nothing, which reads as a rendering bug rather than an eye")
}

@Test func blinkIntervalsAreIrregular() {
    // A metronome blink reads as a machine. Sample the distribution directly.
    let samples = (0..<200).map { _ in Gaze.nextBlinkInterval() }
    let mean = samples.reduce(0, +) / CGFloat(samples.count)
    let spread = samples.map { abs($0 - mean) }.reduce(0, +) / CGFloat(samples.count)
    #expect(mean > 2 && mean < 6, "mean blink interval drifted from ~4s")
    #expect(spread > 1, "blink intervals are too uniform to read as an animal")
    #expect(samples.allSatisfy { $0 >= 0.8 && $0 <= 14 }, "interval escaped its clamp")
}

@Test func lookDirectionSaturatesWithDistance() {
    let head = CGPoint(x: 100, y: 100)
    let near = lookDirection(from: head, to: CGPoint(x: 150, y: 100))
    let far = lookDirection(from: head, to: CGPoint(x: 900, y: 100))
    #expect(near.x > 0 && near.x < 1)
    #expect(abs(far.x - 1) < 0.001, "distant targets should saturate to 'over there'")
    #expect(lookDirection(from: head, to: head) == .zero)
}

// MARK: - Repose (the idle ladder)

@Test func heSettlesTheLongerYouAreAway() {
    // Cats settle when the room goes quiet.
    #expect(Repose.from(idleSeconds: 5) == .awake)
    #expect(Repose.from(idleSeconds: 60) == .sitting)
    #expect(Repose.from(idleSeconds: 240) == .curled)
    #expect(Repose.from(idleSeconds: 900) == .asleep)
}

@Test func languorOnlyKicksInOnLowBatteryOrLowPower() {
    var s = Sensations()
    s.batteryPercent = 80
    #expect(s.languor == 0)

    s.batteryPercent = 15
    #expect(s.languor > 0, "below 20% he should conserve energy")

    s.charging = true
    #expect(s.languor == 0, "plugged in, he perks back up")

    s = Sensations(); s.lowPower = true
    #expect(s.languor == 1, "Low Power Mode should match the machine's mood exactly")
}

@Test func aDesktopMacWithNoBatteryIsNotPermanentlySluggish() {
    // IOPS returns nothing on a Mac mini or Studio. Treating that as 0% would leave him
    // permanently exhausted on every desktop Mac.
    var s = Sensations()
    s.batteryPercent = nil
    #expect(s.languor == 0)
}
