import CoreGraphics
import Foundation

/// Per-port signal history feeding the cable and module animations,
/// modeled on Bespoke Synth's trio of NoteHistory (gate events sweep
/// down the cable over 250 ms), IModulator's smoothed-value recent
/// change (the blue↔red modulation overlay), and the RollingBuffer viz
/// tap (the cable drawn as the waveform it carries).
///
/// Written by PatchRuntime at the end of every render block and read by
/// the UI through AudioEngine's snapshot methods; the RuntimeBox lock
/// serializes the two sides, so nothing here locks.
final class SignalTap {
    /// Bespoke NOTE_HISTORY_LENGTH: seconds for an event to travel the
    /// full cable, and the note-highlight decay time on modules.
    static let historyLength = 0.25
    /// Bespoke NoteHistory::kHistorySize.
    static let historySize = 100
    /// Rolling audio window shown along a cable, ~21 ms at 48 kHz.
    static let vizSize = 1024
    /// Gate-high threshold, matching the runtime's module semantics.
    static let gateThreshold: Float = 0.5

    struct GateEvent {
        var on = false
        var time = 0.0
    }

    // MARK: Gate history (CV ports)

    private var history = [GateEvent](repeating: GateEvent(), count: SignalTap.historySize)
    private var historyPos = 0
    private(set) var lastOnEventTime = -999.0
    private var gateHigh = false

    // MARK: Recent change (CV ports)

    private(set) var lastValue: Float = 0
    private(set) var smoothedValue: Float = 0
    var recentChange: Float { lastValue - smoothedValue }

    // MARK: Audio viz ring (audio ports)

    private(set) var isAudio = false
    private var viz = [Float](repeating: 0, count: SignalTap.vizSize)
    private var vizHead = 0

    func updateCV(_ value: Float, time: Double, blocksPerSecond: Double) {
        let high = value >= Self.gateThreshold
        if high != gateHigh {
            gateHigh = high
            if high { lastOnEventTime = time }
            historyPos = (historyPos + 1) % Self.historySize
            history[historyPos] = GateEvent(on: high, time: time)
        }
        // Bespoke IModulator::Poll — exp2 blend is framerate-independent,
        // so updating per control block instead of per UI frame keeps the
        // same time constant.
        let blend = Float(exp2(-9.65784 / max(blocksPerSecond, 1)))
        lastValue = value
        smoothedValue = smoothedValue * blend + value * (1 - blend)
    }

    func updateAudio(_ samples: [Float]) {
        isAudio = true
        for s in samples {
            viz[vizHead] = s
            vizHead = (vizHead + 1) % Self.vizSize
        }
    }

    /// Events newest-first, ending with the first one older than the
    /// travel window — the Bespoke draw loop needs that one terminator.
    func recentEvents(now: Double) -> [GateEvent] {
        var events: [GateEvent] = []
        for ago in 0..<Self.historySize {
            let event = history[(historyPos + Self.historySize - ago) % Self.historySize]
            guard event.time > 0 else { break }
            events.append(event)
            if now - event.time >= Self.historyLength { break }
        }
        return events
    }

    /// Samples newest-first: index i is the sample i frames ago, the
    /// order Bespoke's cable draw consumes (newest at the source end).
    func vizSnapshot() -> [Float] {
        var snapshot = [Float](repeating: 0, count: Self.vizSize)
        for ago in 0..<Self.vizSize {
            snapshot[ago] = viz[(vizHead + Self.vizSize - 1 - ago) % Self.vizSize]
        }
        return snapshot
    }

    /// Bespoke IDrawableModule::DrawFrame audio highlight: fourth root
    /// of mean square over the last ≤500 samples, ×3, clamped, ×0.15.
    func audioHighlight() -> Float {
        let count = min(500, Self.vizSize)
        var meanSquare: Float = 0
        for ago in 0..<count {
            let s = viz[(vizHead + Self.vizSize - 1 - ago) % Self.vizSize]
            meanSquare += s * s
        }
        meanSquare /= Float(count)
        let mag = min(max(meanSquare.squareRoot().squareRoot() * 3, 0), 1)
        return mag * 0.15
    }

    /// Bespoke note highlight: 0.15 decaying linearly over 250 ms from
    /// the last gate-on edge.
    func noteHighlight(now: Double) -> Float {
        let elapsed = Float((now - lastOnEventTime) / Self.historyLength)
        return 0.15 * min(max(1 - elapsed, 0), 1)
    }
}

/// The Bespoke cable animation formulas, kept pure for tests.
enum CableAnimation {
    /// Seconds per bar for the tempo throb on a traveling pulse.
    /// Bespoke syncs to its transport; ZoiaCanvas has none, so this is
    /// fixed at Bespoke's default 120 BPM 4/4 bar.
    static let barSeconds = 2.0

    /// Line width of a lit gate segment (PatchCable.cpp:260): starts 5×,
    /// decays to 2×, with a bar-synced cosine shimmer on top.
    static func litWidth(elapsed: Double, sinceEvent: Double) -> Double {
        2 + min(max(1 - elapsed * 0.7, 0), 1) * 3
            + cos(sinceEvent * .pi * 8 / barSeconds) * 0.3
    }

    /// Audio sample → cable displacement fraction: signed square root
    /// soft-compression, clamped ±1 (PatchCable.cpp:359).
    static func compress(_ sample: Float) -> Float {
        let c = sample.magnitude.squareRoot() * (sample < 0 ? -1 : 1)
        return min(max(c, -1), 1)
    }

    /// Modulation overlay alpha for a normalized recent-change delta
    /// (PatchCable.cpp:216): flares on change, fades at rest.
    static func modulationAlpha(_ delta: Float) -> Float {
        abs(1 - (1 - delta) * (1 - delta)) * (150.0 / 255.0)
    }

    /// Bespoke kHighlightGrowAmount: world points a module frame
    /// inflates per unit of highlight.
    static let highlightGrow: CGFloat = 40
}

/// Arc-length parameterization of a cable path, so pulses travel at
/// constant speed and waveform samples space evenly on beziers and
/// angular routes alike.
struct PathSampler {
    private var points: [CGPoint]
    private var cumulative: [CGFloat]
    private(set) var length: CGFloat

    init(polyline: [CGPoint]) {
        points = polyline.count > 1 ? polyline : polyline + polyline
        var cumulative: [CGFloat] = [0]
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            cumulative.append(total)
        }
        self.cumulative = cumulative
        length = total
    }

    init(from: CGPoint, control1: CGPoint, control2: CGPoint, to: CGPoint,
         segments: Int = 48) {
        var sampled: [CGPoint] = []
        for i in 0...segments {
            let t = CGFloat(i) / CGFloat(segments)
            let u = 1 - t
            sampled.append(CGPoint(
                x: u * u * u * from.x + 3 * u * u * t * control1.x
                    + 3 * u * t * t * control2.x + t * t * t * to.x,
                y: u * u * u * from.y + 3 * u * u * t * control1.y
                    + 3 * u * t * t * control2.y + t * t * t * to.y))
        }
        self.init(polyline: sampled)
    }

    /// Point at an arc-length fraction 0…1.
    func point(at fraction: CGFloat) -> CGPoint {
        let target = min(max(fraction, 0), 1) * length
        guard length > 0 else { return points[0] }
        var low = 0
        var high = cumulative.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if cumulative[mid] <= target { low = mid } else { high = mid }
        }
        let span = cumulative[high] - cumulative[low]
        let t = span > 0 ? (target - cumulative[low]) / span : 0
        return CGPoint(
            x: points[low].x + (points[high].x - points[low].x) * t,
            y: points[low].y + (points[high].y - points[low].y) * t)
    }

    /// Unit normal at an arc-length fraction, for waveform displacement.
    func perpendicular(at fraction: CGFloat) -> CGPoint {
        let target = min(max(fraction, 0), 1) * length
        guard length > 0 else { return CGPoint(x: 0, y: -1) }
        var low = 0
        var high = cumulative.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if cumulative[mid] <= target { low = mid } else { high = mid }
        }
        let dx = points[high].x - points[low].x
        let dy = points[high].y - points[low].y
        let len = hypot(dx, dy)
        guard len > 0 else { return CGPoint(x: 0, y: -1) }
        return CGPoint(x: -dy / len, y: dx / len)
    }
}
