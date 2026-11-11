import AppKit
import CoreGraphics

/// Lyssnar globalt på tal-knappen via ett CGEventTap (kräver behörigheten Hjälpmedel).
/// Vanliga tangenter "sväljs" så att de inte skrivs in i det aktiva programmet.
/// Ensamma modifierare (t.ex. höger ⌘) släpps igenom; om en annan tangent trycks medan
/// modifieraren hålls ned tolkas det som ett vanligt kortkommando och inspelningen avbryts.
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Anropas när en ensam modifierare används ihop med en annan tangent (t.ex. ⌘C).
    var onCancel: (() -> Void)?

    var hotkey: Hotkey
    /// Pausar avlyssningen (t.ex. medan ett nytt kortkommando spelas in i inställningarna).
    var isSuspended = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            NSLog("Transkribering: kunde inte skapa event tap (saknas behörighet för Hjälpmedel?)")
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if isSuspended { return Unmanaged.passUnretained(event) }
        // Ignorera tangenttryckningar som appen själv skickar när texten skrivs ut (t.ex. ⌘V medan
        // höger ⌘ hålls ned) – annars skulle de tolkas som ett kortkommando och avbryta inspelningen.
        if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if hotkey.isModifierOnly {
            switch type {
            case .flagsChanged where keyCode == hotkey.keyCode:
                let mask = Hotkey.modifierKeyMasks[keyCode] ?? 0
                let pressed = event.flags.rawValue & mask != 0
                if pressed && !isDown {
                    isDown = true
                    onPress?()
                } else if !pressed && isDown {
                    isDown = false
                    onRelease?()
                }
            case .keyDown where isDown:
                // Modifieraren används i ett kortkommando, inte som tal-knapp.
                isDown = false
                onCancel?()
            default:
                break
            }
            return Unmanaged.passUnretained(event)
        }

        guard keyCode == hotkey.keyCode else { return Unmanaged.passUnretained(event) }
        switch type {
        case .keyDown:
            let flags = event.flags.intersection(Hotkey.relevantModifiers)
            guard flags == hotkey.requiredFlags || isDown else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 && !isDown {
                isDown = true
                onPress?()
            }
            return nil
        case .keyUp:
            guard isDown else { return Unmanaged.passUnretained(event) }
            isDown = false
            onRelease?()
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
