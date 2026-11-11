import Foundation

struct TranscriptionOptions {
    /// Namn och termer som modellen bör stava som de är skrivna (stöds av t.ex. Pianissimo).
    var vocabulary: [String] = []
}

/// Gemensamt gränssnitt för transkriberingsmotorer. Appen pratar bara med detta protokoll,
/// så en ny modelltyp kan läggas till utan att resten av appen ändras.
protocol TranscriptionEngine: AnyObject {
    /// Statusmeddelanden under laddning (t.ex. "Laddar ner modell…").
    var onStatus: ((String) -> Void)? { get set }

    /// Laddar (och vid behov laddar ner) modellen. Kan anropas igen för att byta modell.
    func prepare(model: ModelSpec) async throws

    /// Transkriberar 16 kHz mono-ljud. De första `contextSamples` sampeln är tidigare ljud som bara ger
    /// modellen sammanhang (vid löpande utskrift); endast texten efter dem returneras.
    func transcribe(samples: [Float], contextSamples: Int, options: TranscriptionOptions) async throws -> String

    func shutdown()
}

/// Väljer motor utifrån fältet `engine` i modellkatalogen.
///
/// Idag körs alla motorer i den lokala Python-backenden (backend/engines), som har en egen
/// registrering per motornamn. Vill man köra en modell direkt i Swift (t.ex. via Core ML eller
/// WhisperKit) skapar man en ny klass som följer TranscriptionEngine och returnerar den här.
enum EngineFactory {
    static func backendKind(for model: ModelSpec) -> String {
        switch model.engine {
        // case "whisperkit": return "native-whisperkit"
        default: return "python"
        }
    }

    static func make(for model: ModelSpec) -> TranscriptionEngine {
        switch backendKind(for: model) {
        default: return PythonWorkerEngine()
        }
    }
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
