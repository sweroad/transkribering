import Foundation

/// Kör transkriberingen i en lokal Python-process (backend/worker.py) med MLX på Apple silicon.
/// Processen startas vid behov, behåller modellen i minnet och startas om automatiskt om den kraschar.
/// Kommunikation: en JSON-rad per meddelande över stdin/stdout.
final class PythonWorkerEngine: TranscriptionEngine, @unchecked Sendable {
    var onStatus: ((String) -> Void)?

    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextId = 1
    private var loadedModel: ModelSpec?

    deinit { shutdown() }

    // MARK: TranscriptionEngine

    func prepare(model: ModelSpec) async throws {
        try startIfNeeded()
        let spec = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model))
        _ = try await request(["cmd": "load", "model": spec])
        lock.withLock { loadedModel = model }
    }

    func transcribe(samples: [Float], contextSamples: Int, options: TranscriptionOptions) async throws -> String {
        // Starta om processen och ladda modellen igen om den har avslutats.
        let (running, model) = lock.withLock { (process?.isRunning == true, loadedModel) }
        if !running {
            guard let model else { throw EngineError(message: "Ingen modell är laddad") }
            try await prepare(model: model)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transkribering-\(UUID().uuidString).f32")
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }  // Float32 little-endian
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let response = try await request([
            "cmd": "transcribe",
            "audio_path": url.path,
            "sample_rate": Int(AudioRecorder.sampleRate),
            "vocabulary": options.vocabulary,
            "context_seconds": Double(contextSamples) / AudioRecorder.sampleRate,
        ])
        return (response["text"] as? String) ?? ""
    }

    func shutdown() {
        let proc: Process? = lock.withLock {
            let p = process
            process = nil
            return p
        }
        guard let proc, proc.isRunning else { return }
        if let line = try? JSONSerialization.data(withJSONObject: ["id": 0, "cmd": "shutdown"]) {
            input?.write(line + Data([0x0A]))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if proc.isRunning { proc.terminate() }
        }
    }

    // MARK: Process

    private func startIfNeeded() throws {
        try lock.withLock {
            if process?.isRunning == true { return }

            let python = AppPaths.venvPython
            guard FileManager.default.isExecutableFile(atPath: python.path) else {
                throw EngineError(message: "Python-miljön saknas. Öppna Inställningar → Modell och klicka på "
                                  + "”Installera backend”, eller kör scripts/setup_backend.sh.")
            }
            guard let worker = AppPaths.resource("backend/worker.py") else {
                throw EngineError(message: "Hittar inte backend/worker.py i appen.")
            }

            let proc = Process()
            proc.executableURL = python
            proc.arguments = [worker.path]
            var env = ProcessInfo.processInfo.environment
            env["HF_HOME"] = AppPaths.modelCache.path
            env["HF_HUB_DISABLE_TELEMETRY"] = "1"
            env["PYTHONUNBUFFERED"] = "1"
            // Skriv inte .pyc-filer i det signerade app-paketet.
            env["PYTHONPYCACHEPREFIX"] = AppPaths.support.appendingPathComponent("pycache").path
            env["PYTHONIOENCODING"] = "utf-8"
            env["TOKENIZERS_PARALLELISM"] = "false"
            proc.environment = env

            let stdinPipe = Pipe(), stdoutPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            FileManager.default.createFile(atPath: AppPaths.workerLog.path, contents: nil)
            proc.standardError = (try? FileHandle(forWritingTo: AppPaths.workerLog)) ?? FileHandle.nullDevice

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                self?.receive(data)
            }
            proc.terminationHandler = { [weak self] p in
                self?.processEnded(p)
            }

            try proc.run()
            process = proc
            input = stdinPipe.fileHandleForWriting
            outputBuffer.removeAll()
            loadedModel = nil
        }
    }

    private func processEnded(_ p: Process) {
        let waiting: [CheckedContinuation<[String: Any], Error>] = lock.withLock {
            let w = Array(pending.values)
            pending.removeAll()
            if process === p { process = nil }
            return w
        }
        let error = EngineError(message: "Transkriberingsprocessen avslutades oväntat (kod \(p.terminationStatus)). "
                                + "Se \(AppPaths.workerLog.path)")
        waiting.forEach { $0.resume(throwing: error) }
    }

    private func request(_ body: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            var message = body
            let handle: FileHandle? = lock.withLock {
                let id = nextId
                nextId += 1
                message["id"] = id
                pending[id] = continuation
                return input
            }
            do {
                guard let handle else { throw EngineError(message: "Transkriberingsprocessen körs inte") }
                let line = try JSONSerialization.data(withJSONObject: message)
                try handle.write(contentsOf: line + Data([0x0A]))
            } catch {
                let id = message["id"] as! Int
                let c = lock.withLock { pending.removeValue(forKey: id) }
                c?.resume(throwing: error)
            }
        }
    }

    private func receive(_ data: Data) {
        var lines: [Data] = []
        lock.withLock {
            outputBuffer.append(data)
            while let newline = outputBuffer.firstIndex(of: 0x0A) {
                lines.append(outputBuffer[outputBuffer.startIndex..<newline])
                outputBuffer.removeSubrange(outputBuffer.startIndex...newline)
            }
        }
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let event = obj["event"] as? String {
                if event == "status", let message = obj["message"] as? String {
                    let callback = onStatus
                    DispatchQueue.main.async { callback?(message) }
                }
                continue
            }
            guard let id = obj["id"] as? Int else { continue }
            let continuation = lock.withLock { pending.removeValue(forKey: id) }
            if obj["ok"] as? Bool == true {
                continuation?.resume(returning: obj)
            } else {
                continuation?.resume(throwing: EngineError(message: (obj["error"] as? String) ?? "Okänt fel"))
            }
        }
    }
}
