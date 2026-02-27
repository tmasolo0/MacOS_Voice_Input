import AppKit
import Foundation

/// Service for inserting transcribed text at the cursor position via clipboard + Cmd+V simulation.
/// Preserves original clipboard content by saving and restoring after insertion.
/// Falls back to clipboard-only mode (no Cmd+V) when secure input is active.
struct TextInsertionService {

    /// Insert text at the current cursor position.
    /// - Parameters:
    ///   - text: The text to insert.
    ///   - secureInput: If true, copies text to clipboard and shows notification instead of simulating paste.
    ///   - targetApp: The app that was focused when recording started — focus will be restored before paste.
    @MainActor
    func insert(_ text: String, secureInput: Bool, targetApp: NSRunningApplication? = nil) async {
        // Guard: empty or whitespace-only text — nothing to do
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if secureInput {
            insertSecure(text)
        } else {
            await insertNormal(text, targetApp: targetApp)
        }
    }

    // MARK: - Secure Input Path

    /// In secure input mode, just copy text to clipboard and notify the user.
    @MainActor
    private func insertSecure(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Show macOS notification — use NSSound alert as simple feedback
        NSSound.beep()
        DiagnosticLogger.shared.info("Secure input active — text copied to clipboard", category: "Insertion")
    }

    // MARK: - Normal Insertion Path

    /// Save clipboard, write text, restore focus, simulate Cmd+V, wait, restore clipboard.
    @MainActor
    private func insertNormal(_ text: String, targetApp: NSRunningApplication?) async {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard contents (all types for each item)
        let savedChangeCount = pasteboard.changeCount
        var savedItems: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeData[type] = data
                }
            }
            savedItems.append(typeData)
        }

        // 2. Write text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Mark as transient so clipboard managers ignore it
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))

        // 3. Restore focus to the app that was active when recording started
        if let app = targetApp {
            app.activate()
            // Brief pause to let the app come to front
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        // 4. Simulate Cmd+V
        simulatePaste()

        // 5. Wait for paste to complete
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // 6. Restore original clipboard (only if no other app modified it)
        let expectedChangeCount = savedChangeCount + 1
        if pasteboard.changeCount == expectedChangeCount {
            pasteboard.clearContents()
            for typeData in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in typeData {
                    item.setData(data, forType: type)
                }
                pasteboard.writeObjects([item])
            }
            DiagnosticLogger.shared.info("Clipboard restored", category: "Insertion")
        } else {
            DiagnosticLogger.shared.warning("Clipboard changed externally (expected \(expectedChangeCount), got \(pasteboard.changeCount)), skipping restore", category: "Insertion")
        }
    }

    // MARK: - CGEvent Paste Simulation

    /// Simulate Cmd+V keypress via CGEvent.
    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 0x09 = V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
