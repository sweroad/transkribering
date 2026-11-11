import Foundation
import Combine

enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    /// Håll ned knappen medan du pratar.
    case pushToTalk
    /// Tryck en gång för att börja, en gång till för att sluta.
    case toggle

    var id: String { rawValue }
    var label: String {
        switch self {
        case .pushToTalk: return "Håll ned för att prata"
        case .toggle: return "Tryck för att starta/stoppa"
        }
    }
}

/// Användarinställningar, sparade i UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published var hotkey: Hotkey { didSet { save(hotkey, "hotkey") } }
    @Published var mode: RecordingMode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var modelId: String { didSet { defaults.set(modelId, forKey: "modelId") } }
    @Published var insertionMethod: InsertionMethod { didSet { defaults.set(insertionMethod.rawValue, forKey: "insertionMethod") } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard") } }
    @Published var appendSpace: Bool { didSet { defaults.set(appendSpace, forKey: "appendSpace") } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: "playSounds") } }
    /// Ett ord eller en fras per rad.
    @Published var vocabularyText: String { didSet { defaults.set(vocabularyText, forKey: "vocabulary") } }

    /// Skriv ut texten löpande vid pauser i talet i stället för allt när knappen släpps.
    @Published var streamingEnabled: Bool { didSet { defaults.set(streamingEnabled, forKey: "streamingEnabled") } }
    /// Så lång paus (sekunder) som avslutar en fras vid löpande utskrift.
    @Published var pauseDuration: Double { didSet { defaults.set(pauseDuration, forKey: "pauseDuration") } }
    /// Röstkommandon som "utropstecken" → "!" och "ny rad" → radbrytning.
    @Published var voiceCommandsEnabled: Bool { didSet { defaults.set(voiceCommandsEnabled, forKey: "voiceCommandsEnabled") } }
    /// Id:n för inbyggda kommandon som användaren har stängt av.
    @Published var disabledCommandIds: Set<String> { didSet { defaults.set(Array(disabledCommandIds), forKey: "disabledCommandIds") } }
    /// Egna kommandon, en per rad: `fras = ersättning`.
    @Published var customCommandsText: String { didSet { defaults.set(customCommandsText, forKey: "customCommands") } }

    var activeVoiceCommands: [VoiceCommand] {
        guard voiceCommandsEnabled else { return [] }
        return VoiceCommand.builtIn.filter { !disabledCommandIds.contains($0.id) }
            + VoiceCommand.parseCustom(customCommandsText)
    }

    var vocabulary: [String] {
        vocabularyText.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private init() {
        defaults.register(defaults: [
            "restoreClipboard": true, "appendSpace": true, "playSounds": true, "voiceCommandsEnabled": true,
            "streamingEnabled": true, "pauseDuration": 0.7,
        ])
        streamingEnabled = defaults.bool(forKey: "streamingEnabled")
        pauseDuration = defaults.double(forKey: "pauseDuration")
        voiceCommandsEnabled = defaults.bool(forKey: "voiceCommandsEnabled")
        disabledCommandIds = Set(defaults.stringArray(forKey: "disabledCommandIds") ?? [])
        customCommandsText = defaults.string(forKey: "customCommands") ?? ""
        hotkey = (defaults.data(forKey: "hotkey")).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
            ?? .defaultHotkey
        mode = RecordingMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .pushToTalk
        modelId = defaults.string(forKey: "modelId") ?? ""
        insertionMethod = InsertionMethod(rawValue: defaults.string(forKey: "insertionMethod") ?? "") ?? .paste
        restoreClipboard = defaults.bool(forKey: "restoreClipboard")
        appendSpace = defaults.bool(forKey: "appendSpace")
        playSounds = defaults.bool(forKey: "playSounds")
        vocabularyText = defaults.string(forKey: "vocabulary") ?? ""
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
