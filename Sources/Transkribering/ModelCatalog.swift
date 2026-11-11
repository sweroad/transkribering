import Foundation

/// Godtyckligt JSON-värde, så att motorspecifika inställningar ("options") kan skickas vidare oförändrade.
enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

/// En transkriberingsmodell. `engine` avgör vilken motor som kör den (se EngineFactory och backend/engines).
struct ModelSpec: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var engine: String
    var repo: String
    var revision: String?
    var language: String?
    var size: String?
    var notes: String?
    var options: [String: JSONValue]?
}

private struct CatalogFile: Codable {
    var `default`: String?
    var models: [ModelSpec]
}

/// Läser modellkatalogen: den inbyggda (Resources/models.json) plus användarens egen
/// (~/Library/Application Support/Transkribering/models.json). Poster med samma id i användarfilen vinner.
enum ModelCatalog {
    static var userCatalogURL: URL { AppPaths.support.appendingPathComponent("models.json") }

    static func load() -> (models: [ModelSpec], defaultId: String?) {
        var models: [ModelSpec] = []
        var defaultId: String?

        for url in [AppPaths.resource("models.json"), userCatalogURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let file = try JSONDecoder().decode(CatalogFile.self, from: data)
                if let d = file.default { defaultId = d }
                for model in file.models {
                    if let i = models.firstIndex(where: { $0.id == model.id }) { models[i] = model }
                    else { models.append(model) }
                }
            } catch {
                NSLog("Transkribering: kunde inte läsa modellkatalog \(url.path): \(error)")
            }
        }
        return (models, defaultId)
    }
}
