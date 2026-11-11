import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralTab(controller: controller, settings: settings)
                .tabItem { Label("Allmänt", systemImage: "keyboard") }
            ModelTab(controller: controller, settings: settings)
                .tabItem { Label("Modell", systemImage: "cpu") }
            VoiceCommandsTab(settings: settings)
                .tabItem { Label("Röstkommandon", systemImage: "textformat.abc") }
            VocabularyTab(settings: settings)
                .tabItem { Label("Ordlista", systemImage: "text.book.closed") }
        }
        .frame(width: 560, height: 560)
    }
}

// MARK: - Allmänt

private struct GeneralTab: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var hasMicrophone = AudioRecorder.hasPermission
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Tal-knapp") {
                LabeledContent("Tangent") {
                    HotkeyRecorder(hotkey: $settings.hotkey, onCaptureChange: controller.setHotkeyCaptureActive)
                }
                Picker("Läge", selection: $settings.mode) {
                    ForEach(RecordingMode.allCases) { Text($0.label).tag($0) }
                }
                Text(settings.hotkey.isModifierOnly
                     ? "En ensam modifierare fungerar som vanligt i kortkommandon (t.ex. ⌘C); då avbryts inspelningen."
                     : "Tangenten fångas upp och skickas inte vidare till andra program.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Löpande utskrift") {
                Toggle("Skriv ut texten medan jag pratar", isOn: $settings.streamingEnabled)
                if settings.streamingEnabled {
                    LabeledContent("Paus som avslutar en fras") {
                        HStack {
                            Slider(value: $settings.pauseDuration, in: 0.4...1.5, step: 0.1).frame(width: 180)
                            Text(String(format: "%.1f s", settings.pauseDuration)).monospacedDigit()
                        }
                    }
                    Text("Varje fras skrivs ut när du gör en kort paus. Kortare paus ger snabbare utskrift men "
                         + "fler meningsbrott; längre paus ger mer sammanhang åt modellen.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("All text skrivs ut när du släpper knappen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Inmatning") {
                Picker("Metod", selection: $settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases) { Text($0.label).tag($0) }
                }
                if settings.insertionMethod == .paste {
                    Toggle("Återställ urklipp efter inklistring", isOn: $settings.restoreClipboard)
                }
                Toggle("Lägg till mellanslag efter texten", isOn: $settings.appendSpace)
                Toggle("Spela ljud vid start/stopp", isOn: $settings.playSounds)
            }

            Section("System") {
                Toggle("Starta vid inloggning", isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.launchAtLogin = $0 }))
                PermissionRow(title: "Hjälpmedel (tal-knapp och textinmatning)", granted: hasAccessibility) {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
                PermissionRow(title: "Mikrofon", granted: hasMicrophone) {
                    Task { _ = await AudioRecorder.requestPermission() }
                    Permissions.openMicrophoneSettings()
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            hasAccessibility = Permissions.hasAccessibility
            hasMicrophone = AudioRecorder.hasPermission
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text(title)
            Spacer()
            if !granted { Button("Ge behörighet…", action: action) }
        }
    }
}

// MARK: - Kortkommandoinspelning

/// Knapp som spelar in en ny tal-knapp: en vanlig tangent (med modifierare) eller en ensam modifierare.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    var onCaptureChange: (Bool) -> Void
    @State private var isCapturing = false
    @State private var monitor: Any?
    @State private var pendingModifier: UInt16?

    var body: some View {
        HStack {
            Button(action: toggle) {
                Text(isCapturing ? "Tryck på en tangent…" : hotkey.displayName)
                    .frame(minWidth: 160)
            }
            .buttonStyle(.bordered)
            .tint(isCapturing ? .accentColor : nil)
            if isCapturing {
                Button("Avbryt") { stop() }
            } else if hotkey != .defaultHotkey {
                Button("Återställ") { hotkey = .defaultHotkey }
            }
        }
        .onDisappear { stop() }
    }

    private func toggle() { isCapturing ? stop() : start() }

    private func start() {
        isCapturing = true
        pendingModifier = nil
        onCaptureChange(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isCapturing = false
        onCaptureChange(false)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                stop()  // Esc avbryter
                return
            }
            hotkey = Hotkey(keyCode: event.keyCode, modifiers: Hotkey.flags(from: event.modifierFlags))
            stop()
        case .flagsChanged:
            guard let mask = Hotkey.modifierKeyMasks[event.keyCode] else { return }
            let pressed = UInt64(event.modifierFlags.rawValue) & mask != 0
            if pressed {
                pendingModifier = event.keyCode
            } else if pendingModifier == event.keyCode {
                // Modifieraren trycktes och släpptes utan annan tangent: använd den ensam.
                hotkey = Hotkey(keyCode: event.keyCode, modifiers: 0)
                stop()
            }
        default:
            break
        }
    }
}

// MARK: - Modell

private struct ModelTab: View {
    @ObservedObject var controller: AppController
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Transkriberingsmodell") {
                Picker("Modell", selection: $settings.modelId) {
                    ForEach(controller.models) { model in
                        Text(model.size.map { "\(model.name) (\($0))" } ?? model.name).tag(model.id)
                    }
                }
                if let model = controller.currentModel {
                    LabeledContent("Källa", value: model.repo)
                    LabeledContent("Motor", value: model.engine)
                    if let notes = model.notes {
                        Text(notes).font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Status") { StatusLabel(state: controller.state) }
                HStack {
                    Button("Ladda om modellen") { controller.loadModel() }
                    Button("Läs om modellkatalog") { controller.reloadCatalog(); controller.loadModel() }
                    Spacer()
                    Button("Visa modellmapp") { NSWorkspace.shared.open(AppPaths.support) }
                }
                Text("Modellerna laddas ner en gång till \(AppPaths.modelCache.path) och körs sedan helt lokalt. "
                     + "Egna modeller läggs till i \(ModelCatalog.userCatalogURL.path).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section("Lokal backend (Python + MLX)") {
                HStack {
                    Image(systemName: FileManager.default.isExecutableFile(atPath: AppPaths.venvPython.path)
                          ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(AppPaths.venvPython.path).font(.caption).textSelection(.enabled)
                }
                HStack {
                    Button(controller.isInstallingBackend ? "Installerar…" : "Installera/uppdatera backend") {
                        controller.installBackend()
                    }.disabled(controller.isInstallingBackend)
                    Button("Visa logg") { NSWorkspace.shared.open(AppPaths.workerLog) }
                }
                if !controller.installLog.isEmpty {
                    ScrollView {
                        Text(controller.installLog)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }.frame(height: 100)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct StatusLabel: View {
    let state: AppController.State

    var body: some View {
        switch state {
        case .loading(let message):
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(message) }
        case .ready:
            Label("Redo", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .recording:
            Label("Spelar in", systemImage: "mic.fill").foregroundStyle(.red)
        case .transcribing:
            Label("Transkriberar", systemImage: "waveform")
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .lineLimit(3).textSelection(.enabled)
        }
    }
}

// MARK: - Röstkommandon

private struct VoiceCommandsTab: View {
    @ObservedObject var settings: AppSettings
    @State private var testInput = "hej utropstecken ny rad hur mår du frågetecken"

    var body: some View {
        Form {
            Section {
                Toggle("Tolka röstkommandon", isOn: $settings.voiceCommandsEnabled)
                Text("Säg t.ex. ”utropstecken” för ! eller ”ny rad” för en radbrytning. Modellen sätter också ut "
                     + "skiljetecken på egen hand; kommandon ger dig full kontroll när du behöver det.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Inbyggda kommandon") {
                ForEach(VoiceCommand.builtIn) { command in
                    Toggle(isOn: Binding(
                        get: { !settings.disabledCommandIds.contains(command.id) },
                        set: { on in
                            if on { settings.disabledCommandIds.remove(command.id) }
                            else { settings.disabledCommandIds.insert(command.id) }
                        })) {
                        HStack {
                            Text(command.phrases.map { "”\($0)”" }.joined(separator: ", "))
                            Spacer()
                            Text(command.displayReplacement)
                                .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(!settings.voiceCommandsEnabled)

            Section("Egna kommandon") {
                TextEditor(text: $settings.customCommandsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                Text("En per rad: fras = ersättning. Flera fraser med |, \\n ger ny rad. Exempel:\n"
                     + "mvh = Med vänliga hälsningar\nsmiley = :)\nutrotstecken | utropsteckan = !")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .disabled(!settings.voiceCommandsEnabled)

            Section("Prova") {
                TextField("Skriv som modellen skulle transkribera", text: $testInput)
                Text(VoiceCommandProcessor(commands: settings.activeVoiceCommands).process(testInput)
                        .replacingOccurrences(of: "\n", with: "⏎\n"))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Ordlista

private struct VocabularyTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Namn och facktermer som modellen ska stava som de är skrivna. Ett ord eller en fras per rad.")
                .foregroundStyle(.secondary)
            TextEditor(text: $settings.vocabularyText)
                .font(.body)
                .border(Color.secondary.opacity(0.3))
            Text("Pianissimo använder ”phrase boosting”, Whisper-modeller använder listan som inledande prompt.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}
