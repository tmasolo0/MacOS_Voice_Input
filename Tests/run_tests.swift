#!/usr/bin/env swift
// Standalone test runner for TextProcessingService
// Required because Xcode is not installed (only CommandLineTools)
// The implementation is copied from Sources/Solo_STT/Services/TextProcessingService.swift

import Foundation

// ======= Test Infrastructure =======

var totalTests = 0
var passedTests = 0
var failedTests: [(name: String, expected: String, got: String)] = []

func assertEqual(_ result: String, _ expected: String, test: String) {
    totalTests += 1
    if result == expected {
        passedTests += 1
        print("  PASS: \(test)")
    } else {
        failedTests.append((name: test, expected: expected, got: result))
        print("  FAIL: \(test)")
        print("    Expected: \"\(expected)\"")
        print("    Got:      \"\(result)\"")
    }
}

// ======= TextProcessingService (copied from Sources/Solo_STT/Services/TextProcessingService.swift) =======

struct TextProcessingService {

    func process(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return "" }

        result = removeFillers(result)
        result = collapseSpaces(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return "" }

        result = fixPunctuationSpacing(result)
        result = collapseSpaces(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return "" }

        result = ensureTrailingPunctuation(result)
        result = capitalizeFirst(result)
        result = capitalizeAfterSentenceEnd(result)

        return result
    }

    private func removeFillers(_ text: String) -> String {
        var result = text

        let multiWordFillers = ["то есть", "как бы"]
        for filler in multiWordFillers {
            result = removeFillerPhrase(result, phrase: filler, caseInsensitive: false)
        }

        let englishMultiWordFillers = ["you know", "I mean"]
        for filler in englishMultiWordFillers {
            result = removeFillerPhrase(result, phrase: filler, caseInsensitive: true)
        }

        let russianFillers = ["ну", "эм", "типа", "вот", "значит", "короче"]
        let englishFillers = ["um", "uh", "erm", "basically"]

        for filler in russianFillers {
            result = removeSimpleFiller(result, word: filler, caseInsensitive: false)
        }
        result = removeSimpleFiller(result, word: "э", caseInsensitive: false)

        for filler in englishFillers {
            result = removeSimpleFiller(result, word: filler, caseInsensitive: true)
        }

        result = collapseSpaces(result)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        result = removeContextFiller(result, word: "like")
        result = removeContextFiller(result, word: "so")

        return result
    }

    private func removeFillerPhrase(_ text: String, phrase: String, caseInsensitive: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: ",?\\s*\(escaped)\\s*,?", options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
    }

    private func removeSimpleFiller(_ text: String, word: String, caseInsensitive: Bool) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []

        if let betweenCommas = try? NSRegularExpression(pattern: ",\\s*\\b\(escaped)\\b\\s*,", options: options) {
            let range = NSRange(text.startIndex..., in: text)
            let result = betweenCommas.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: ",")
            if result != text {
                return removeStandaloneFiller(result, escaped: escaped, options: options)
            }
        }
        return removeStandaloneFiller(text, escaped: escaped, options: options)
    }

    private func removeStandaloneFiller(_ text: String, escaped: String, options: NSRegularExpression.Options) -> String {
        guard let regex = try? NSRegularExpression(pattern: ",?\\s*\\b\(escaped)\\b\\s*,?", options: options) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
    }

    private func removeContextFiller(_ text: String, word: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: word)

        if let startRegex = try? NSRegularExpression(pattern: "^(?i)\(escaped)\\s+", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            let result = startRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            if result != text { return result }
        }

        if let afterPunctRegex = try? NSRegularExpression(pattern: "([.!?]\\s+)(?i)\(escaped)\\s+", options: []) {
            let range = NSRange(text.startIndex..., in: text)
            return afterPunctRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1")
        }

        return text
    }

    private func collapseSpaces(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\s{2,}", options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
    }

    private func fixPunctuationSpacing(_ text: String) -> String {
        var result = text

        if let regex = try? NSRegularExpression(pattern: "\\s+([.,!?])", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }

        if let regex = try? NSRegularExpression(pattern: "^\\s*,\\s*", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        if let regex = try? NSRegularExpression(pattern: ",\\s*$", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        if let regex = try? NSRegularExpression(pattern: ",\\s*,", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: ",")
        }

        return result
    }

    private func ensureTrailingPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = trimmed.last else { return text }
        if lastChar == "." || lastChar == "!" || lastChar == "?" { return trimmed }
        return trimmed + "."
    }

    private func capitalizeFirst(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private func capitalizeAfterSentenceEnd(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "([.!?])\\s+(\\S)", options: []) else { return text }
        var result = text
        let nsString = result as NSString
        let range = NSRange(location: 0, length: nsString.length)

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

// ======= Tests =======

let sut = TextProcessingService()

print("\n=== TextProcessingService Tests ===\n")

print("-- Empty / Whitespace Input --")
assertEqual(sut.process(""), "", test: "Empty string returns empty")
assertEqual(sut.process("   "), "", test: "Whitespace-only returns empty")

print("\n-- Russian Filler Removal --")
assertEqual(sut.process("ну типа привет как дела"), "Привет как дела.", test: "Removes Russian fillers: ну, типа")
assertEqual(sut.process("Привет. ну как бы нормально"), "Привет. Нормально.", test: "Removes Russian multi-word filler: как бы")
assertEqual(sut.process("это, э, хороший день"), "Это, хороший день.", test: "Removes Russian filler with comma: э")
assertEqual(sut.process("ну"), "", test: "Filler-only input returns empty")
assertEqual(sut.process("то есть мы идем домой"), "Мы идем домой.", test: "Removes Russian filler: то есть")
assertEqual(sut.process("значит это так"), "Это так.", test: "Removes Russian filler: значит")
assertEqual(sut.process("короче давай"), "Давай.", test: "Removes Russian filler: короче")
assertEqual(sut.process("вот такие дела"), "Такие дела.", test: "Removes Russian filler: вот")
assertEqual(sut.process("эм подожди"), "Подожди.", test: "Removes Russian filler: эм")

print("\n-- English Filler Removal --")
assertEqual(sut.process("um so basically hello"), "Hello.", test: "Removes English fillers: um, so, basically")
assertEqual(sut.process("you know it works"), "It works.", test: "Removes English filler: you know")
assertEqual(sut.process("I mean it is fine"), "It is fine.", test: "Removes English filler: I mean")
assertEqual(sut.process("uh wait a moment"), "Wait a moment.", test: "Removes English filler: uh")
assertEqual(sut.process("erm let me think"), "Let me think.", test: "Removes English filler: erm")

print("\n-- Context-Dependent Fillers --")
assertEqual(sut.process("I like cats"), "I like cats.", test: "'like' NOT removed in context")
assertEqual(sut.process("like what are you doing"), "What are you doing.", test: "'like' removed at sentence start")
assertEqual(sut.process("there is so much to do"), "There is so much to do.", test: "'so' NOT removed in context")
assertEqual(sut.process("so let us begin"), "Let us begin.", test: "'so' removed at sentence start")

print("\n-- Capitalization --")
assertEqual(sut.process("hello world"), "Hello world.", test: "Capitalizes first character")
assertEqual(sut.process("hello. world"), "Hello. World.", test: "Capitalizes after period")
assertEqual(sut.process("wow! great"), "Wow! Great.", test: "Capitalizes after exclamation")
assertEqual(sut.process("really? yes"), "Really? Yes.", test: "Capitalizes after question mark")
assertEqual(sut.process("привет. мир"), "Привет. Мир.", test: "Capitalizes Russian after period")

print("\n-- Punctuation --")
assertEqual(sut.process("hello world"), "Hello world.", test: "Adds period if missing")
assertEqual(sut.process("Hello world."), "Hello world.", test: "Does not add period if present")
assertEqual(sut.process("Hello world!"), "Hello world!", test: "Does not add period after exclamation")
assertEqual(sut.process("Hello world?"), "Hello world?", test: "Does not add period after question mark")
assertEqual(sut.process("hello  world"), "Hello world.", test: "Collapses double spaces")
assertEqual(sut.process("hello ."), "Hello.", test: "Removes space before period")
assertEqual(sut.process("hello , world"), "Hello, world.", test: "Removes space before comma")

print("\n-- Idempotency --")
assertEqual(sut.process("Hello world."), "Hello world.", test: "Already correct text unchanged")
assertEqual(sut.process("Great job!"), "Great job!", test: "Already correct with exclamation")

print("\n-- Single Word --")
assertEqual(sut.process("hello"), "Hello.", test: "Single word capitalized with period")

print("\n-- Mixed Scenarios --")
assertEqual(sut.process("ну э значит давай"), "Давай.", test: "Multiple Russian fillers")
assertEqual(sut.process("Хорошо. ну ладно"), "Хорошо. Ладно.", test: "Filler between sentences")
assertEqual(sut.process("um uh basically yes"), "Yes.", test: "Multiple English fillers")

print("\n=== Results ===")
print("Total: \(totalTests), Passed: \(passedTests), Failed: \(failedTests.count)")

if !failedTests.isEmpty {
    print("\nFailed tests:")
    for f in failedTests {
        print("  - \(f.name): expected \"\(f.expected)\", got \"\(f.got)\"")
    }
    exit(1)
} else {
    print("\nAll tests passed!")
    exit(0)
}
