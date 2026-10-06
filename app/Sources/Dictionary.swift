import AppKit
import Foundation
import CoreServices

/// One dictionary entry, already split into what the UI needs.
struct DictionaryEntry {
    /// What the user typed (may be an inflected form: "electrons" resolves to "electron").
    let query: String
    let headword: String
    let phonetics: String
    let body: String
    let raw: String

    /// Single line for the strip under the search field.
    var brief: String {
        let oneLine = body.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 160 ? String(oneLine.prefix(160)) + "…" : oneLine
    }
}

/// Lookups through the system dictionary service: offline, ~2–3 ms, no permissions.
///
/// Measured on this machine: 20 lookups of the same word took 2 ms, so a lookup per keystroke
/// is affordable; the dictionary also folds inflections ("electrons" → "electron").
/// Styled presentation for the detail window.
///
/// Reading hierarchy that matters for a 英汉 dictionary: the Chinese gloss is the primary
/// text, the English grammar scaffolding (part of speech, labels, pinyin) recedes, sense
/// numbers carry the accent colour and examples are indented and dimmed.
struct DictionaryPresentation {
    let partOfSpeech: String
    let body: NSAttributedString

    private static let partsOfSpeech: Set<String> = [
        "noun", "verb", "adjective", "adverb", "preposition", "pronoun", "conjunction",
        "determiner", "exclamation", "abbreviation", "combining form", "number", "auxiliary verb"
    ]

    init(entry: DictionaryEntry) {
        var detected = ""
        let output = NSMutableAttributedString()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let exampleParagraph = NSMutableParagraphStyle()
        exampleParagraph.lineSpacing = 2
        exampleParagraph.firstLineHeadIndent = 16
        exampleParagraph.headIndent = 16

        let lines = Dictionary.format(entry.body).components(separatedBy: "\n")
        var wroteSomething = false

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Single-sense entries keep the part of speech inline ("noun 脉冲星 màichōngxīng"),
            // so it is split off here to feed the pill; multi-sense entries have it on its own
            // line and fall through to the branch below.
            if let space = line.firstIndex(of: " ") {
                let first = String(line[line.startIndex..<space])
                if Self.partsOfSpeech.contains(first.lowercased()) {
                    if detected.isEmpty { detected = first }
                    line = String(line[line.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            guard !line.isEmpty else { continue }

            if Self.partsOfSpeech.contains(line.lowercased()) {
                if detected.isEmpty { detected = line }
                if wroteSomething { output.append(NSAttributedString(string: "\n")) }
                output.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: NSColor.controlAccentColor,
                    .paragraphStyle: paragraph
                ]))
                wroteSomething = true
                continue
            }

            let isExample = line.hasPrefix("▸")
            let isSense = line.first.map { "①②③④⑤⑥⑦⑧⑨⑩".contains($0) } ?? false
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: isExample ? 12 : 13.5),
                .paragraphStyle: isExample ? exampleParagraph : paragraph
            ]
            if isExample {
                attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                attributes[.obliqueness] = 0.12
            }

            let piece = NSMutableAttributedString(string: line, attributes: attributes)
            if isExample {
                // dimmed as a whole
            } else if isSense {
                piece.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                   range: NSRange(location: 0, length: 1))
                Self.colourByScript(piece, from: 1)
            } else {
                Self.colourByScript(piece, from: 0)
            }

            if wroteSomething { output.append(NSAttributedString(string: "\n")) }
            output.append(piece)
            wroteSomething = true
        }

        partOfSpeech = detected
        body = output
    }

    /// Non-ASCII (Chinese) runs take the primary colour, ASCII runs (English labels, pinyin)
    /// recede to the secondary colour.
    private static func colourByScript(_ text: NSMutableAttributedString, from start: Int) {
        let string = text.string as NSString
        var index = start
        while index < string.length {
            let isAscii = string.character(at: index) < 128
            var end = index
            while end < string.length, (string.character(at: end) < 128) == isAscii { end += 1 }
            text.addAttribute(.foregroundColor,
                              value: isAscii ? NSColor.secondaryLabelColor : NSColor.labelColor,
                              range: NSRange(location: index, length: end - index))
            index = end
        }
    }
}

enum Dictionary {
    private static var cache: [String: DictionaryEntry?] = [:]
    private static let lock = NSLock()

    /// A bare ASCII word is the case worth showing a gloss for; anything else is ordinary
    /// searching. (The explicit `d <word>` prefix bypasses this.)
    static func isCandidate(_ query: String) -> Bool {
        let word = query.trimmed()
        guard word.count >= 3, !word.contains(" ") else { return false }
        return word.allSatisfy { $0.isLetter && $0.isASCII }
    }

    static func lookUp(_ query: String) -> DictionaryEntry? {
        let key = query.trimmed().lowercased()
        guard !key.isEmpty else { return nil }
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let entry = rawLookup(key)

        lock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = entry
        lock.unlock()
        return entry
    }

    private static func rawLookup(_ word: String) -> DictionaryEntry? {
        let range = CFRange(location: 0, length: word.utf16.count)
        guard let raw = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String?
        else { return nil }

        let parts = raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        // An English entry always has the shape `headword | phonetics | body`. A single-part
        // answer is a Chinese dictionary entry, and for a bare ASCII word that is nearly
        // always a pinyin collision — "ran" returns 蚺 rán, which must not be shown as if it
        // were the English word. Words with punctuation ("e-mail", "Dr.") are kept.
        let bareAsciiWord = word.allSatisfy { $0.isLetter && $0.isASCII }
        if parts.count < 3 && bareAsciiWord { return nil }

        let headword = parts.first ?? word
        let phonetics = parts.count >= 3 ? parts[1] : ""
        let body = parts.count >= 3
            ? parts[2...].joined(separator: " | ")
            : parts.joined(separator: " ")
        return DictionaryEntry(query: word, headword: headword, phonetics: phonetics,
                               body: body, raw: raw)
    }

    /// Multi-line layout for the detail window: senses separated, examples indented.
    static func format(_ body: String) -> String {
        var text = body
        if let sense = try? NSRegularExpression(pattern: "\\s*([①②③④⑤⑥⑦⑧⑨⑩])") {
            text = sense.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count),
                                                  withTemplate: "\n\n$1")
        }
        if let example = try? NSRegularExpression(pattern: "\\s*▸\\s*") {
            text = example.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: text.utf16.count),
                                                    withTemplate: "\n    ▸ ")
        }
        if let senseStart = try? NSRegularExpression(pattern: "(noun|verb|adjective|adverb|preposition|abbreviation|combining form)\\s") {
            text = senseStart.stringByReplacingMatches(in: text,
                                                       range: NSRange(location: 0, length: text.utf16.count),
                                                       withTemplate: "\n$1 ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
