import Foundation

/// Delar upp en pågående inspelning i fraser vid pauser i talet, så att varje fras kan transkriberas
/// och skrivas ut medan användaren fortsätter prata. Enkel energibaserad röstaktivitetsdetektering
/// med adaptiv brusnivå.
struct SpeechSegmenter {
    static let frameSize = 320  // 20 ms vid 16 kHz

    /// Så lång tystnad efter tal som avslutar en fras.
    var pauseDuration: TimeInterval
    /// Längre fraser än så här delas vid den tystaste punkten (håller nere fördröjningen).
    var maxSegmentDuration: TimeInterval = 20

    /// Absolut sampelindex där nuvarande fras börjar.
    private(set) var segmentStart = 0
    /// Antal sampel som har analyserats.
    private(set) var analyzed = 0
    /// Antal fraser som har skickats för transkribering.
    private(set) var emittedSegments = 0

    private var noiseFloor: Float = 0.003
    private var speechFrames = 0
    private var silenceRun = 0
    private var frameEnergies: [(end: Int, rms: Float)] = []
    private var pending: [Float] = []

    private var sampleRate: Int { Int(AudioRecorder.sampleRate) }
    private var pauseFrames: Int { max(5, Int(pauseDuration * Double(sampleRate)) / Self.frameSize) }
    private let minSpeechFrames = 12   // 240 ms tal krävs för att en fras ska räknas
    private let keepTrailingFrames = 20 // 400 ms tystnad följer med i slutet av frasen (svaga slutljud som "t")

    init(pauseDuration: TimeInterval) {
        self.pauseDuration = pauseDuration
    }

    /// Matar in nya sampel (i ordning) och returnerar de fraser som är klara att transkribera.
    mutating func feed(_ samples: [Float]) -> [Range<Int>] {
        pending.append(contentsOf: samples)
        var ranges: [Range<Int>] = []
        var offset = 0
        while pending.count - offset >= Self.frameSize {
            let frame = pending[offset..<(offset + Self.frameSize)]
            offset += Self.frameSize
            analyzed += Self.frameSize
            if let range = analyze(frame) { ranges.append(range) }
        }
        pending.removeFirst(offset)
        return ranges
    }

    /// Den sista frasen när inspelningen stoppas, eller nil om den bara innehåller tystnad.
    mutating func finish(totalSamples: Int) -> Range<Int>? {
        guard totalSamples > segmentStart else { return nil }
        // Om inget tal hörts sedan förra frasen finns inget att transkribera – men har vi inte skickat
        // något alls transkriberar vi hela inspelningen ändå (tyst tal kan ligga under tröskeln).
        if speechFrames == 0 && emittedSegments > 0 { return nil }
        emittedSegments += 1
        return segmentStart..<totalSamples
    }

    private mutating func analyze(_ frame: ArraySlice<Float>) -> Range<Int>? {
        var sum: Float = 0
        for s in frame { sum += s * s }
        let rms = (sum / Float(frame.count)).squareRoot()
        let frameEnd = analyzed
        frameEnergies.append((frameEnd, rms))

        // Brusnivån följer snabbt nedåt och långsamt uppåt.
        noiseFloor = rms < noiseFloor ? 0.9 * noiseFloor + 0.1 * rms : 0.998 * noiseFloor + 0.002 * rms
        let threshold = max(noiseFloor * 3, 0.006)

        if rms > threshold {
            speechFrames += 1
            silenceRun = 0
        } else {
            silenceRun += 1
        }

        // Paus efter tal: frasen är klar.
        if speechFrames >= minSpeechFrames && silenceRun >= pauseFrames {
            let cut = frameEnd - (silenceRun - keepTrailingFrames) * Self.frameSize
            return emit(upTo: cut)
        }

        // Bara tystnad hittills: släpp allt utom de senaste 300 ms så att frasen inte börjar med lång tystnad.
        if speechFrames == 0 && frameEnd - segmentStart > sampleRate {
            segmentStart = frameEnd - sampleRate * 3 / 10
            frameEnergies.removeAll { $0.end <= segmentStart }
        }

        // För lång fras: dela vid den tystaste punkten bland de senaste tre sekunderna.
        if frameEnd - segmentStart >= Int(maxSegmentDuration * Double(sampleRate)) {
            let windowStart = frameEnd - 3 * sampleRate
            let quietest = frameEnergies.filter { $0.end > windowStart }.min { $0.rms < $1.rms }
            return emit(upTo: quietest?.end ?? frameEnd)
        }
        return nil
    }

    private mutating func emit(upTo cut: Int) -> Range<Int>? {
        let range = segmentStart..<max(cut, segmentStart + 1)
        segmentStart = range.upperBound
        speechFrames = 0
        frameEnergies.removeAll { $0.end <= segmentStart }
        emittedSegments += 1
        return range
    }
}
