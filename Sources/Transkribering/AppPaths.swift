import Foundation

enum AppPaths {
    /// ~/Library/Application Support/Transkribering
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Transkribering", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Python-miljön som scripts/setup_backend.sh skapar.
    static var venvPython: URL { support.appendingPathComponent("venv/bin/python") }

    /// Här sparas nedladdade modeller (Hugging Face-cache).
    static var modelCache: URL { support.appendingPathComponent("huggingface", isDirectory: true) }

    static var workerLog: URL { support.appendingPathComponent("worker.log") }

    /// Fil i appens Resources, med reserv till källkodsmappen när appen körs via `swift run`.
    static func resource(_ name: String) -> URL? {
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let candidates = [
            sourceRoot.appendingPathComponent("Resources").appendingPathComponent(name),
            sourceRoot.appendingPathComponent(name),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static var sourceRoot: URL {
        // Sources/Transkribering/AppPaths.swift -> projektroten
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
}
