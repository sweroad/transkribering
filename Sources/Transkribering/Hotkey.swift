import AppKit
import Carbon.HIToolbox

/// En tangent (med eventuella modifierare) som används som tal-knapp.
/// Kan vara en vanlig tangent (t.ex. F13, eller ⌃⌥Mellanslag) eller en ensam modifierare
/// (t.ex. höger ⌘), som då skiljer på höger och vänster sida.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    /// Krävda modifierare för vanliga tangenter (⌘⌥⌃⇧), som CGEventFlags-råvärde.
    var modifiers: UInt64

    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// Höger ⌘ – används sällan till annat på svenskt tangentbord.
    static let defaultHotkey = Hotkey(keyCode: UInt16(kVK_RightCommand), modifiers: 0)

    /// Enhetsberoende flaggbitar (IOKit NX_DEVICE*KEYMASK) per modifierartangent,
    /// så att vi kan avgöra om just höger- eller vänstertangenten är nedtryckt.
    static let modifierKeyMasks: [UInt16: UInt64] = [
        UInt16(kVK_Command): 0x08,
        UInt16(kVK_RightCommand): 0x10,
        UInt16(kVK_Option): 0x20,
        UInt16(kVK_RightOption): 0x40,
        UInt16(kVK_Control): 0x01,
        UInt16(kVK_RightControl): 0x2000,
        UInt16(kVK_Shift): 0x02,
        UInt16(kVK_RightShift): 0x04,
        UInt16(kVK_Function): CGEventFlags.maskSecondaryFn.rawValue,
    ]

    var isModifierOnly: Bool { Hotkey.modifierKeyMasks[keyCode] != nil }

    var requiredFlags: CGEventFlags {
        CGEventFlags(rawValue: modifiers).intersection(Hotkey.relevantModifiers)
    }

    var displayName: String {
        if isModifierOnly { return Hotkey.keyName(keyCode) }
        var s = ""
        let f = requiredFlags
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + Hotkey.keyName(keyCode)
    }

    static func flags(from nsFlags: NSEvent.ModifierFlags) -> UInt64 {
        var f: CGEventFlags = []
        if nsFlags.contains(.command) { f.insert(.maskCommand) }
        if nsFlags.contains(.option) { f.insert(.maskAlternate) }
        if nsFlags.contains(.control) { f.insert(.maskControl) }
        if nsFlags.contains(.shift) { f.insert(.maskShift) }
        return f.rawValue
    }

    static func keyName(_ keyCode: UInt16) -> String {
        let special: [Int: String] = [
            kVK_RightCommand: "Höger ⌘", kVK_Command: "Vänster ⌘",
            kVK_RightOption: "Höger ⌥", kVK_Option: "Vänster ⌥",
            kVK_RightControl: "Höger ⌃", kVK_Control: "Vänster ⌃",
            kVK_RightShift: "Höger ⇧", kVK_Shift: "Vänster ⇧",
            kVK_Function: "fn / 🌐",
            kVK_Space: "Mellanslag", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "Esc",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_CapsLock: "Caps Lock",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_Help: "Help",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
            kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]
        if let name = special[Int(keyCode)] { return name }
        if let char = translate(keyCode) { return char.uppercased() }
        return "Tangent \(keyCode)"
    }

    /// Översätter en tangentkod till tecken enligt aktuell tangentbordslayout.
    private static func translate(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
