import AppKit
import Combine
import ServiceManagement

/// Knyter ihop tal-knapp, inspelning, transkribering och textinmatning.
@MainActor
final class AppController: ObservableObject {
    enum State: Equatable {
        case loading(String)
        case ready
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var state: State = .loading("Startar…")
    @Published private(set) var models: [ModelSpec] = []
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var hotkeyActive = false
    @Published var isInstallingBackend = false
    @Published var installLog = ""

    let settings = AppSettings.shared
    private let recorder = AudioRecorder()
    private let monitor: HotkeyMonitor
    private var engine: TranscriptionEngine?
    private var engineKind: String?
    private var loadTask: Task<Void, Never>?
    private var recordingStarted: Date?
    private var session: DictationSession?
    private var segmenter: SpeechSegmenter?
    private var segmentTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?

    /// Inspelningar kortare än så här ignoreras (t.ex. ett snabbt oavsiktligt tryck).
    private let minimumDuration: TimeInterval = 0.3

    var currentModel: ModelSpec? { models.first { $0.id == settings.modelId } }

    init() {
        monitor = HotkeyMonitor(hotkey: AppSettings.shared.hotkey)
        reloadCatalog()

        monitor.onPress = { [weak self] in Task { @MainActor in self?.hotkeyPressed() } }
        monitor.onRelease = { [weak self] in Task { @MainActor in self?.hotkeyReleased() } }
        monitor.onCancel = { [weak self] in Task { @MainActor in self?.cancelRecording() } }

        settings.$hotkey.dropFirst().sink { [weak self] in self?.monitor.hotkey = $0 }.store(in: &cancellables)
        settings.$modelId.dropFirst().removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.loadModel() }
        }.store(in: &cancellables)
    }

    func start() {
        Task {
            _ = await AudioRecorder.requestPermission()
        }
        startHotkeyMonitor()
        loadModel()
    }

    func shutdown() {
        engine?.shutdown()
    }

    // MARK: Modell

    func reloadCatalog() {
        let catalog = ModelCatalog.load()
        models = catalog.models
        if currentModel == nil {
            settings.modelId = catalog.defaultId ?? models.first?.id ?? ""
        }
    }

    func loadModel() {
        guard let model = currentModel else {
            state = .error("Ingen modell vald")
            return
        }
        loadTask?.cancel()

        let kind = EngineFactory.backendKind(for: model)
        if engine == nil || engineKind != kind {
            engine?.shutdown()
            let newEngine = EngineFactory.make(for: model)
            newEngine.onStatus = { [weak self] message in
                Task { @MainActor in
                    if case .loading = self?.state { self?.state = .loading(message) }
                }
            }
            engine = newEngine
            engineKind = kind
        }

        state = .loading("Laddar \(model.name)…")
        let engine = engine!
        loadTask = Task {
            do {
                try await engine.prepare(model: model)
                guard !Task.isCancelled else { return }
                state = .ready
            } catch {
                guard !Task.isCancelled else { return }
                state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: Tal-knapp

    func startHotkeyMonitor() {
        if !monitor.isRunning {
            if !Permissions.hasAccessibility { Permissions.requestAccessibility() }
            hotkeyActive = monitor.start()
        }
        // Vänta på att användaren ger behörighet och försök sedan igen.
        if !hotkeyActive && permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self else { return timer.invalidate() }
                    if Permissions.hasAccessibility, self.monitor.start() {
                        self.hotkeyActive = true
                        timer.invalidate()
                        self.permissionTimer = nil
                    }
                }
            }
        }
    }

    /// Pausar tal-knappen medan ett nytt kortkommando spelas in i inställningarna.
    func setHotkeyCaptureActive(_ active: Bool) {
        monitor.isSuspended = active
    }

    private func hotkeyPressed() {
        switch settings.mode {
        case .pushToTalk:
            startRecording()
        case .toggle:
            if state == .recording { finishRecording() } else { startRecording() }
        }
    }

    private func hotkeyReleased() {
        if settings.mode == .pushToTalk && state == .recording { finishRecording() }
    }

    func toggleRecordingFromMenu() {
        if state == .recording { finishRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard state == .ready else {
            if case .loading(let message) = state { NSLog("Transkribering: modellen är inte klar: \(message)") }
            NSSound.beep()
            return
        }
        guard AudioRecorder.hasPermission else {
            Task { _ = await AudioRecorder.requestPermission() }
            state = .error("Appen saknar behörighet till mikrofonen")
            return
        }
        guard let engine else { return }
        do {
            try recorder.start()
        } catch {
            state = .error("Kunde inte starta inspelning: \(error.localizedDescription)")
            return
        }
        recordingStarted = Date()
        state = .recording
        if settings.playSounds { NSSound(named: "Tink")?.play() }

        let method = settings.insertionMethod
        let restoreClipboard = settings.restoreClipboard
        session = DictationSession(
            engine: engine,
            options: TranscriptionOptions(vocabulary: settings.vocabulary),
            processor: VoiceCommandProcessor(commands: settings.activeVoiceCommands),
            appendSpace: settings.appendSpace,
            output: { deleteCount, insertion in
                TextInserter.shared.replace(deleting: deleteCount, with: insertion,
                                            method: method, restoreClipboard: restoreClipboard)
            })

        // Löpande utskrift: dela inspelningen vid pauser och transkribera varje fras direkt.
        if settings.streamingEnabled {
            segmenter = SpeechSegmenter(pauseDuration: settings.pauseDuration)
            segmentTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pollSegments() }
            }
        }
    }

    private func pollSegments() {
        guard state == .recording, var segmenter, let session else { return }
        let total = recorder.sampleCount
        guard total > segmenter.analyzed else { return }
        let ranges = segmenter.feed(recorder.samples(in: segmenter.analyzed..<total))
        self.segmenter = segmenter
        for range in ranges { session.enqueue(range, from: recorder.samples(in:)) }
    }

    private func stopSegmenting() {
        segmentTimer?.invalidate()
        segmentTimer = nil
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        // Har en del av texten redan skrivits ut avslutas dikteringen i stället för att kastas.
        if (session?.queuedSegments ?? 0) > 0 { return finishRecording() }
        stopSegmenting()
        _ = recorder.stop()
        session = nil
        segmenter = nil
        state = .ready
    }

    private func finishRecording() {
        guard state == .recording, let session else { return }
        pollSegments()
        stopSegmenting()
        let samples = recorder.stop()
        let duration = Date().timeIntervalSince(recordingStarted ?? Date())
        if settings.playSounds { NSSound(named: "Pop")?.play() }

        let tooShort = duration < minimumDuration || samples.count <= Int(AudioRecorder.sampleRate * minimumDuration)
        if tooShort && session.queuedSegments == 0 {
            self.session = nil
            segmenter = nil
            state = .ready
            return
        }

        // Den sista frasen (eller hela inspelningen om löpande utskrift är avstängd).
        let audio: (Range<Int>) -> [Float] = { Array(samples[$0.clamped(to: 0..<samples.count)]) }
        if var segmenter {
            if let range = segmenter.finish(totalSamples: samples.count) {
                session.enqueue(range, from: audio)
            }
        } else {
            session.enqueue(0..<samples.count, from: audio)
        }
        self.segmenter = nil

        state = .transcribing
        Task {
            await session.finish()
            if !session.finalText.isEmpty { lastTranscript = session.finalText }
            if self.session === session { self.session = nil }
            if let error = session.errors.first {
                state = .error(error.localizedDescription)
            } else {
                state = .ready
            }
        }
    }

    // MARK: Backend-installation

    func installBackend() {
        guard !isInstallingBackend,
              let script = AppPaths.resource("setup_backend.sh") ?? AppPaths.resource("scripts/setup_backend.sh"),
              let requirements = AppPaths.resource("backend/requirements.txt") else {
            installLog = "Hittar inte installationsskriptet i appen."
            return
        }
        isInstallingBackend = true
        installLog = ""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [script.path, requirements.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor in self?.installLog += text }
        }
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                self.isInstallingBackend = false
                self.installLog += p.terminationStatus == 0 ? "\n✓ Klart\n" : "\n✗ Misslyckades (kod \(p.terminationStatus))\n"
                if p.terminationStatus == 0 {
                    self.engine?.shutdown()
                    self.engine = nil
                    self.loadModel()
                }
            }
        }
        do { try proc.run() } catch {
            isInstallingBackend = false
            installLog = "Kunde inte starta installationen: \(error.localizedDescription)"
        }
    }

    // MARK: Starta vid inloggning

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Transkribering: kunde inte ändra start vid inloggning: \(error)")
            }
            objectWillChange.send()
        }
    }
}
