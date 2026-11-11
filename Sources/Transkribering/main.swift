import AppKit
import Combine
import SwiftUI

/// Menyradsapp utan Dock-ikon (LSUIElement). Ikonen visar status: mikrofon = redo,
/// röd = spelar in, vågform = transkriberar, varning = fel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = AppController()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        controller.$state.receive(on: RunLoop.main).sink { [weak self] state in
            self?.updateIcon(for: state)
        }.store(in: &cancellables)

        controller.start()

        // Visa inställningarna första gången så att användaren ser behörigheter och tal-knapp.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            openSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    private func updateIcon(for state: AppController.State) {
        let symbol: String
        switch state {
        case .loading: symbol = "mic.badge.ellipsis"
        case .ready: symbol = "mic"
        case .recording: symbol = "mic.fill"
        case .transcribing: symbol = "waveform"
        case .error: symbol = "mic.slash"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Transkribering")
            ?? NSImage(systemSymbolName: "mic", accessibilityDescription: "Transkribering")
        image?.isTemplate = state != .recording
        if state == .recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            statusItem.button?.image = image?.withSymbolConfiguration(config)
        } else {
            statusItem.button?.image = image
        }
    }

    // MARK: Meny

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let model = controller.currentModel {
            let item = NSMenuItem(title: "Modell: \(model.name)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        let key = NSMenuItem(title: "Tal-knapp: \(controller.settings.hotkey.displayName)"
                             + (controller.hotkeyActive ? "" : " (saknar behörighet)"),
                             action: nil, keyEquivalent: "")
        key.isEnabled = false
        menu.addItem(key)
        menu.addItem(.separator())

        let record = NSMenuItem(title: controller.state == .recording ? "Stoppa inspelning" : "Starta inspelning",
                                action: #selector(toggleRecording), keyEquivalent: "")
        record.target = self
        menu.addItem(record)

        if !controller.lastTranscript.isEmpty {
            let copy = NSMenuItem(title: "Kopiera senaste transkribering", action: #selector(copyLast), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        if case .error = controller.state {
            let retry = NSMenuItem(title: "Försök ladda modellen igen", action: #selector(retry), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Inställningar…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: "Avsluta Transkribering", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    private var statusText: String {
        switch controller.state {
        case .loading(let message): return message
        case .ready: return "Redo – håll ned \(controller.settings.hotkey.displayName) och prata"
        case .recording: return "Spelar in…"
        case .transcribing: return "Transkriberar…"
        case .error(let message): return "Fel: \(message)"
        }
    }

    @objc private func toggleRecording() { controller.toggleRecordingFromMenu() }
    @objc private func retry() { controller.loadModel() }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.lastTranscript, forType: .string)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(controller: controller)))
            window.title = "Transkribering – Inställningar"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

// Felsökning: `Transkribering --process-text "hej utropstecken ny rad"` skriver ut hur röstkommandon tolkas.
if let i = CommandLine.arguments.firstIndex(of: "--process-text") {
    let processor = VoiceCommandProcessor(commands: AppSettings.shared.activeVoiceCommands)
    for input in CommandLine.arguments.dropFirst(i + 1) {
        let output = processor.process(input)
        print("IN:  \(input)\nUT:  \(output.replacingOccurrences(of: "\n", with: "⏎\n     "))\n")
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--simulate-stream"), i + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { StreamSimulator.run(path: CommandLine.arguments[i + 1]) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
