import CoreGraphics
import Carbon
import AppKit
import os.log

private let logger = Logger(subsystem: "com.solo.stt", category: "HotkeyService")

class HotkeyService {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onSecureInputChanged: ((Bool) -> Void)?

    /// Current hotkey keyCode — can be updated without restarting the event tap
    var keyCode: Int64 = 61
    /// Whether the hotkey is a modifier key (Option, Shift, Control, Command, Fn)
    var isModifier: Bool = true

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var secureInputTimer: Timer?
    private var isKeyDown: Bool = false

    func start() {
        startEventTap()
        startSecureInputPolling()
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil

        secureInputTimer?.invalidate()
        secureInputTimer = nil
    }

    deinit {
        stop()
    }

    // MARK: - Event Tap

    private func startEventTap() {
        let eventMask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
                return service.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        )

        guard let eventTap else {
            logger.error("Failed to create event tap - check Accessibility permission")
            return
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logger.info("Event tap created successfully")
    }

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if isModifier {
            return handleModifierEvent(type: type, event: event)
        } else {
            return handleRegularKeyEvent(type: type, event: event)
        }
    }

    // MARK: - Modifier Key Handling (flagsChanged)

    private func handleModifierEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard eventKeyCode == keyCode else {
            return Unmanaged.passUnretained(event)
        }

        let flagActive = isModifierFlagActive(for: keyCode, flags: event.flags)

        if flagActive && !isKeyDown {
            isKeyDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?()
            }
        } else if !flagActive && isKeyDown {
            isKeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func isModifierFlagActive(for keyCode: Int64, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 56, 60:  // Left Shift, Right Shift
            return flags.contains(.maskShift)
        case 59, 62:  // Left Control, Right Control
            return flags.contains(.maskControl)
        case 58, 61:  // Left Option, Right Option
            return flags.contains(.maskAlternate)
        case 55, 54:  // Left Command, Right Command
            return flags.contains(.maskCommand)
        case 63:      // Fn
            return flags.contains(.maskSecondaryFn)
        default:
            return false
        }
    }

    // MARK: - Regular Key Handling (keyDown/keyUp)

    private func handleRegularKeyEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let eventKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard eventKeyCode == keyCode else {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            // Ignore key repeat
            if isKeyDown { return nil }
            isKeyDown = true
            DispatchQueue.main.async { [weak self] in
                self?.onKeyDown?()
            }
            return nil  // Suppress the key
        } else if type == .keyUp {
            guard isKeyDown else { return nil }
            isKeyDown = false
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?()
            }
            return nil  // Suppress the key
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Secure Input Polling

    private func startSecureInputPolling() {
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            let secure = IsSecureEventInputEnabled()
            DispatchQueue.main.async {
                self?.onSecureInputChanged?(secure)
            }
        }
    }

    // MARK: - Key Name

    static func keyName(for keyCode: Int, isModifier: Bool) -> String {
        if isModifier {
            switch keyCode {
            case 56: return "Left Shift"
            case 60: return "Right Shift"
            case 59: return "Left Control"
            case 62: return "Right Control"
            case 58: return "Left Option"
            case 61: return "Right Option"
            case 55: return "Left Command"
            case 54: return "Right Command"
            case 63: return "Fn"
            default: return "Modifier \(keyCode)"
            }
        }

        // F-keys
        switch keyCode {
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64:  return "F17"
        case 79:  return "F18"
        case 80:  return "F19"
        case 90:  return "F20"
        default: break
        }

        // Special keys
        switch keyCode {
        case 36:  return "Return"
        case 48:  return "Tab"
        case 49:  return "Space"
        case 51:  return "Delete"
        case 53:  return "Escape"
        case 76:  return "Enter"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: break
        }

        // Letter/number keys — use Carbon to get the character
        if let name = carbonKeyName(for: keyCode) {
            return name.uppercased()
        }

        return "Key \(keyCode)"
    }

    private static func carbonKeyName(for keyCode: Int) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length: Int = 0

        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    /// Set of keyCodes that are modifier keys
    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
}
