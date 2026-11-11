import AppKit
import Carbon.HIToolbox

enum InsertionMethod: String, Codable, CaseIterable, Identifiable {
    /// Lägger texten på urklipp, skickar ⌘V och återställer sedan urklippet. Snabbt och pålitligt.
    case paste
    /// Skriver texten som tangenttryckningar. Fungerar där inklistring är blockerad, men är långsammare.
    case type

    var id: String { rawValue }
    var label: String {
        switch self {
        case .paste: return "Klistra in (snabbast)"
        case .type: return "Skriv som tangenttryckningar"
        }
    }
}

/// Skriver in text där markören står i det aktiva programmet (kräver behörigheten Hjälpmedel).
///
/// Operationerna körs i tur och ordning med en kort paus emellan, så att mottagande program hinner
/// läsa urklippet innan nästa inklistring. Urklippet sparas en gång före första inklistringen och
/// återställs när det varit tyst en stund – även när texten skrivs ut löpande i flera delar.
@MainActor
final class TextInserter {
    static let shared = TextInserter()

    /// Markerar händelser som appen själv skickar, så att HotkeyMonitor kan ignorera dem.
    nonisolated static let syntheticEventMarker: Int64 = 0x5452_414E  // "TRAN"

    private struct Operation {
        var deleteCount: Int
        var text: String
        var method: InsertionMethod
        var restoreClipboard: Bool
    }

    private var queue: [Operation] = []
    private var isBusy = false
    private var savedClipboard: [NSPasteboardItem]?
    private var ourChangeCount: Int?
    private var restoreWork: DispatchWorkItem?

    func insert(_ text: String, method: InsertionMethod, restoreClipboard: Bool) {
        replace(deleting: 0, with: text, method: method, restoreClipboard: restoreClipboard)
    }

    /// Raderar `deleteCount` tecken bakåt och skriver sedan `text`.
    func replace(deleting deleteCount: Int, with text: String, method: InsertionMethod, restoreClipboard: Bool) {
        guard deleteCount > 0 || !text.isEmpty else { return }
        queue.append(Operation(deleteCount: deleteCount, text: text, method: method, restoreClipboard: restoreClipboard))
        runNext()
    }

    private func runNext() {
        guard !isBusy, !queue.isEmpty else { return }
        isBusy = true
        let op = queue.removeFirst()
        restoreWork?.cancel()

        let source = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<op.deleteCount { press(CGKeyCode(kVK_Delete), source: source) }

        var delay = op.deleteCount > 0 ? 0.03 : 0
        if !op.text.isEmpty {
            switch op.method {
            case .paste:
                paste(op.text, restoreClipboard: op.restoreClipboard, source: source)
                delay = 0.15
            case .type:
                type(op.text, source: source)
                delay = max(delay, 0.03)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.isBusy = false
            if self.queue.isEmpty { self.scheduleClipboardRestore() } else { self.runNext() }
        }
    }

    // MARK: Inklistring

    private func paste(_ text: String, restoreClipboard: Bool, source: CGEventSource?) {
        let pasteboard = NSPasteboard.general
        if restoreClipboard && savedClipboard == nil {
            savedClipboard = Self.snapshot(pasteboard)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ourChangeCount = pasteboard.changeCount
        press(CGKeyCode(kVK_ANSI_V), flags: .maskCommand, source: source)
    }

    private func scheduleClipboardRestore() {
        guard let saved = savedClipboard else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            // Rör inte urklippet om något annat har ändrat det under tiden.
            if pasteboard.changeCount == self.ourChangeCount {
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
            self.savedClipboard = nil
            self.ourChangeCount = nil
        }
        restoreWork = work
        // Vänta så att mottagande program hinner läsa urklippet innan det återställs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    // MARK: Tangenttryckningar

    /// Skriver texten som tangenttryckningar; radbrytningar skickas som riktiga Enter-tryck.
    private func type(_ text: String, source: CGEventSource?) {
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                press(CGKeyCode(kVK_Return), source: source)
                usleep(5_000)
            }
            typeUnicode(line, source: source)
        }
    }

    private func typeUnicode(_ text: String, source: CGEventSource?) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 20, units.count)
            var chunk = Array(units[index..<end])
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                Self.post(event)
            }
            index = end
            usleep(2_000)
        }
    }

    private func press(_ key: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: keyDown)
            event?.flags = flags
            Self.post(event)
        }
    }

    private static func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event?.post(tap: .cghidEventTap)
    }
}
