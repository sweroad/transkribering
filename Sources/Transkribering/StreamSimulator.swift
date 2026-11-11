import Foundation

/// Felsökning: `Transkribering --simulate-stream ljud.f32` spelar upp en ljudfil (rå float32, 16 kHz mono)
/// i realtid genom pausdetektering, modell och röstkommandon, och skriver ut vad som skulle ha
/// matats in i det aktiva programmet och när.
@MainActor
enum StreamSimulator {
    static func run(path: String) {
        guard let data = FileManager.default.contents(atPath: path) else {
            print("Kan inte läsa \(path)"); exit(1)
        }
        let audio = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let settings = AppSettings.shared
        let catalog = ModelCatalog.load()
        guard let model = catalog.models.first(where: { $0.id == settings.modelId })
                ?? catalog.models.first(where: { $0.id == catalog.defaultId }) else {
            print("Ingen modell"); exit(1)
        }

        Task { @MainActor in
            let engine = EngineFactory.make(for: model)
            do { try await engine.prepare(model: model) } catch { print("Fel: \(error)"); exit(1) }

            let start = Date()
            func stamp() -> String { String(format: "%5.2f s", Date().timeIntervalSince(start)) }
            var screen = ""
            let session = DictationSession(
                engine: engine, options: TranscriptionOptions(vocabulary: settings.vocabulary),
                processor: VoiceCommandProcessor(commands: settings.activeVoiceCommands),
                appendSpace: settings.appendSpace,
                output: { deleteCount, insertion in
                    screen.removeLast(min(deleteCount, screen.count))
                    screen += insertion
                    let shown = insertion.replacingOccurrences(of: "\n", with: "⏎")
                    print("[\(stamp())] " + (deleteCount > 0 ? "radera \(deleteCount), " : "") + "skriv «\(shown)»")
                })

            var segmenter = SpeechSegmenter(pauseDuration: settings.pauseDuration)
            let chunk = Int(AudioRecorder.sampleRate / 10)
            var position = 0
            print("[\(stamp())] ▶︎ inspelning startar (\(String(format: "%.1f", Double(audio.count) / 16000)) s ljud)")
            while position < audio.count {
                let end = min(position + chunk, audio.count)
                for range in segmenter.feed(Array(audio[position..<end])) {
                    print("[\(stamp())] – fras \(String(format: "%.2f–%.2f s", Double(range.lowerBound) / 16000, Double(range.upperBound) / 16000))")
                    session.enqueue(range, from: { Array(audio[$0]) })
                }
                position = end
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            print("[\(stamp())] ■ knappen släpps")
            if let range = segmenter.finish(totalSamples: audio.count) {
                print("[\(stamp())] – sista fras \(String(format: "%.2f–%.2f s", Double(range.lowerBound) / 16000, Double(range.upperBound) / 16000))")
                session.enqueue(range, from: { Array(audio[$0]) })
            }
            await session.finish()
            print("[\(stamp())] klart\n\n--- Resultat ---\n\(screen)\n----------------")
            engine.shutdown()
            exit(0)
        }
        RunLoop.main.run()
    }
}
