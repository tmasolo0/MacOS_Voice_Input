import Foundation

struct TextProcessingService {

    /// Process raw transcription text: remove fillers, fix punctuation, apply capitalization.
    func process(_ text: String) -> String {
        // 1. Trim whitespace
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return "" }

        // 2. Remove filler words
        result = removeFillers(result)

        // 3. Collapse multiple spaces, trim
        result = collapseSpaces(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return "" }

        // 4. Fix spacing around punctuation
        result = fixPunctuationSpacing(result)

        // 5. Collapse spaces again after punctuation fixes
        result = collapseSpaces(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return "" }

        // 6. Ensure trailing punctuation
        result = ensureTrailingPunctuation(result)

        // 7. Capitalize first character
        result = capitalizeFirst(result)

        // 8. Capitalize after sentence-ending punctuation
        result = capitalizeAfterSentenceEnd(result)

        return result
    }

    // MARK: - Filler Removal

    private func removeFillers(_ text: String) -> String {
        var result = text

        // Multi-word fillers first (order matters: longer phrases before shorter)
        let multiWordFillers = [
            // Russian multi-word
            "то есть",
            "как бы",
        ]

        for filler in multiWordFillers {
            result = removeFillerPhrase(result, phrase: filler, caseInsensitive: false)
        }

        // English multi-word fillers
        let englishMultiWordFillers = [
            "you know",
            "I mean",
        ]

        for filler in englishMultiWordFillers {
            result = removeFillerPhrase(result, phrase: filler, caseInsensitive: true)
        }

        // Simple fillers (word boundary matching)
        let russianFillers = ["ну", "эм", "типа", "значит", "короче"]
        let englishFillers = ["um", "uh", "erm", "basically"]

        for filler in russianFillers {
            result = removeSimpleFiller(result, word: filler, caseInsensitive: false)
        }

        // Russian "э" needs special handling because it's a single character
        result = removeSimpleFiller(result, word: "э", caseInsensitive: false)

        for filler in englishFillers {
            result = removeSimpleFiller(result, word: filler, caseInsensitive: true)
        }

        // Collapse and trim between passes so context-dependent fillers can detect sentence start
        result = collapseSpaces(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Context-dependent fillers: "like" and "so"
        // Only removed at sentence start or after sentence-ending punctuation
        // Must run after other fillers are removed so positions are correct
        result = removeContextFiller(result, word: "like")
        result = removeContextFiller(result, word: "so")

        return result
    }

    /// Remove a filler word/phrase that appears between commas, at start, or standalone.
    /// When filler appears as ", filler," -> keeps one comma: ","
    /// When filler appears at start "filler ..." -> removes filler
    private func removeFillerPhrase(_ text: String, phrase: String, caseInsensitive: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []

        // Pattern: optional comma+space before, the phrase, optional comma+space after
        // Use replacement that preserves surrounding structure
        guard let regex = try? NSRegularExpression(
            pattern: ",?\\s*\(escaped)\\s*,?",
            options: options
        ) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
    }

    /// Remove a simple single-word filler with word boundary matching.
    /// Handles fillers between commas: ", э," -> ","
    private func removeSimpleFiller(_ text: String, word: String, caseInsensitive: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []

        // First handle: ", word," -> "," (filler between commas — keep one comma)
        if let betweenCommas = try? NSRegularExpression(
            pattern: ",\\s*\\b\(escaped)\\b\\s*,",
            options: options
        ) {
            let range = NSRange(text.startIndex..., in: text)
            let result = betweenCommas.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: ",")
            if result != text {
                // Also remove standalone occurrences
                return removeStandaloneFiller(result, escaped: escaped, options: options)
            }
        }

        return removeStandaloneFiller(text, escaped: escaped, options: options)
    }

    private func removeStandaloneFiller(_ text: String, escaped: String, options: NSRegularExpression.Options) -> String {
        // Remove filler with optional surrounding comma+space
        guard let regex = try? NSRegularExpression(
            pattern: ",?\\s*\\b\(escaped)\\b\\s*,?",
            options: options
        ) else { return text }

        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
    }

    /// Remove context-dependent fillers (like, so) only at sentence start.
    /// "like what" at start -> "what"
    /// "I like cats" -> unchanged
    private func removeContextFiller(_ text: String, word: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)

        // At absolute start of text
        if let startRegex = try? NSRegularExpression(
            pattern: "^(?i)\(escaped)\\s+",
            options: []
        ) {
            let range = NSRange(text.startIndex..., in: text)
            let result = startRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            if result != text {
                return result
            }
        }

        // After sentence-ending punctuation: ". like " -> ". "
        if let afterPunctRegex = try? NSRegularExpression(
            pattern: "([.!?]\\s+)(?i)\(escaped)\\s+",
            options: []
        ) {
            let range = NSRange(text.startIndex..., in: text)
            return afterPunctRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
        }

        return text
    }

    // MARK: - Space Collapsing

    private func collapseSpaces(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\s{2,}", options: []) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
    }

    // MARK: - Punctuation Spacing

    private func fixPunctuationSpacing(_ text: String) -> String {
        var result = text

        // Remove space before period, comma, exclamation, question mark
        if let regex = try? NSRegularExpression(pattern: "\\s+([.,!?])", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        // Remove leading comma or space-comma
        if let regex = try? NSRegularExpression(pattern: "^\\s*,\\s*", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Remove trailing comma (before potential period insertion)
        if let regex = try? NSRegularExpression(pattern: ",\\s*$", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Fix double commas
        if let regex = try? NSRegularExpression(pattern: ",\\s*,", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: ",")
        }

        return result
    }

    // MARK: - Trailing Punctuation

    private func ensureTrailingPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last else { return text }
        if lastChar == "." || lastChar == "!" || lastChar == "?" {
            return trimmed
        }
        return trimmed + "."
    }

    // MARK: - Capitalization

    private func capitalizeFirst(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func capitalizeAfterSentenceEnd(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([.!?])\\s+(\\S)", options: []) else {
            return text
        }
        var result = text
        let nsString = result as NSString
        let range = NSRange(location: 0, length: nsString.length)

        // Find all matches and replace in reverse to preserve ranges
        let matches = regex.matches(in: result, options: [], range: range)
        for match in matches.reversed() {
            let letterRange = match.range(at: 2)
            if let swiftRange = Range(letterRange, in: result) {
                let letter = String(result[swiftRange])
                result = result.replacingCharacters(in: swiftRange, with: letter.uppercased())
            }
        }

        return result
    }
}
