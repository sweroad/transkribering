import Foundation

/// En diktering från tryck till släpp. Fraser transkriberas i tur och ordning och texten skrivs ut
/// löpande. Röstkommandon tolkas på hela texten hittills, så att t.ex. "komma" i början av en ny fras
/// kan fästa mot föregående fras. Avslutande skiljetecken hålls tillbaka tills nästa fras kommit,
/// eftersom nästa fras kan ändra dem ("Hej. Utropstecken." → "Hej!").
@MainActor
final class DictationSession {
    /// Ta bort `deleteCount` tecken bakåt och skriv sedan `insertion`.
    typealias Output = (_ deleteCount: Int, _ insertion: String) -> Void

    private let engine: TranscriptionEngine
    private let options: TranscriptionOptions
    private let processor: VoiceCommandProcessor
    private let appendSpace: Bool
    private let output: Output

    private var rawSegments: [String] = []
    private var inserted = ""
    private var chain: Task<Void, Never>?
    private(set) var errors: [Error] = []
    private(set) var finalText = ""
    private(set) var queuedSegments = 0

    private static let heldBack: Set<Character> = [" ", ".", ",", ";", ":", "!", "?", "…"]

    init(engine: TranscriptionEngine, options: TranscriptionOptions, processor: VoiceCommandProcessor,
         appendSpace: Bool, output: @escaping Output) {
        self.engine = engine
        self.options = options
        self.processor = processor
        self.appendSpace = appendSpace
        self.output = output
    }

    /// Så mycket tidigare ljud som skickas med som sammanhang. Korta fraser som "ny rad" känns igen
    /// mycket säkrare när modellen hör slutet av föregående mening.
    static let contextDuration: TimeInterval = 4

    /// Lägger frasen `range` ur `audio` i kön för transkribering, med föregående ljud som kontext.
    /// Fraserna hanteras i den ordning de kommer.
    func enqueue(_ range: Range<Int>, from audio: (Range<Int>) -> [Float]) {
        let contextStart = queuedSegments == 0
            ? range.lowerBound
            : max(0, range.lowerBound - Int(Self.contextDuration * AudioRecorder.sampleRate))
        let samples = audio(contextStart..<range.upperBound)
        let contextSamples = min(range.lowerBound - contextStart, samples.count)
        queuedSegments += 1
        let previous = chain
        chain = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let text = try await self.engine.transcribe(samples: samples, contextSamples: contextSamples,
                                                            options: self.options)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    // Modellen avslutar varje fras med punkt eftersom ljudet tar slut där. Börjar nästa fras
                    // med liten bokstav (modellen hörde sammanhanget och fortsätter meningen) tas punkten bort.
                    if text.first?.isLowercase == true, let last = self.rawSegments.indices.last,
                       self.rawSegments[last].hasSuffix("."), !self.rawSegments[last].hasSuffix("..") {
                        self.rawSegments[last].removeLast()
                    }
                    self.rawSegments.append(text)
                    self.update(final: false)
                }
            } catch {
                self.errors.append(error)
            }
        }
    }

    /// Väntar in alla fraser och skriver ut resten av texten.
    func finish() async {
        await chain?.value
        update(final: true)
    }

    private func update(final: Bool) {
        var text = processor.process(rawSegments.joined(separator: " "))
        text = String(text.drop(while: { $0 == " " }))
        while text.last == " " { text.removeLast() }

        let target: String
        if final {
            finalText = text
            target = text + (appendSpace && !text.isEmpty && text.last?.isNewline != true ? " " : "")
        } else {
            var stable = text
            while let last = stable.last, Self.heldBack.contains(last) { stable.removeLast() }
            target = stable
        }

        let common = zip(inserted, target).prefix(while: { $0 == $1 }).count
        let deleteCount = inserted.count - common
        let insertion = String(target.dropFirst(common))
        guard deleteCount > 0 || !insertion.isEmpty else { return }
        inserted = target
        output(deleteCount, insertion)
    }
}
