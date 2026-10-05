import Foundation

/// Match quality, highest first:
///   exact 10000 > prefix 8000 > initials 6500 > word-start 6000 > substring 4000
///
/// A path-only match scores 1000 and is used only when no title matched at all, so
/// that a directory name can never outrank a real name match.
enum Ranking {
    static func titleScore(searchTitle: String, initialsLower: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }

        if searchTitle == query { return 10000 }

        if searchTitle.hasPrefix(query) {
            return 8000 - min(searchTitle.count - query.count, 400)
        }

        if !initialsLower.isEmpty, initialsLower.hasPrefix(query) {
            return 6500 - min(searchTitle.count - query.count, 200)
        }

        if let index = wordStartIndex(in: searchTitle, query: query) {
            return 6000 - min(index * 2, 400)
        }

        if let range = searchTitle.range(of: query) {
            let index = searchTitle.distance(from: searchTitle.startIndex, to: range.lowerBound)
            return 4000 - min(index, 1000)
        }

        return nil
    }

    static func pathScore(pathLower: String, query: String) -> Int? {
        guard !query.isEmpty else { return nil }
        return pathLower.contains(query) ? 1000 : nil
    }

    /// File rows, scored on the name ladder plus a depth nudge, so the copy the user means
    /// (a shallow one) wins and equal scores keep a deterministic order.
    static func fileScore(name: String, pathLower: String, query: String) -> Int {
        let lowerName = name.lowercased()
        let stem = (lowerName as NSString).deletingPathExtension
        var best = titleScore(searchTitle: lowerName,
                              initialsLower: initials(of: stem).lowercased(),
                              query: query) ?? 0
        if !stem.isEmpty, stem != lowerName,
           let stemScore = titleScore(searchTitle: stem, initialsLower: "", query: query) {
            best = max(best, stemScore)
        }
        // A match that only exists in the parent folders is much weaker than a name match.
        if best == 0 { best = pathLower.contains(query) ? 1000 : 0 }
        guard best > 0 else { return 0 }
        let depth = pathLower.split(separator: "/").count
        return best + depthBonus(for: depth)
    }

    /// Shallower paths score higher; bounded so it can never outrank a better name match.
    static func depthBonus(for depth: Int) -> Int {
        max(0, 80 - depth * 5)
    }

    /// Index of the first occurrence that starts a word, or nil.
    private static func wordStartIndex(in haystack: String, query: String) -> Int? {
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: query, range: searchStart..<haystack.endIndex) {
            if range.lowerBound == haystack.startIndex {
                return 0
            }
            let previous = haystack[haystack.index(before: range.lowerBound)]
            if !previous.isLetter && !previous.isNumber {
                return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            }
            searchStart = range.upperBound
            if searchStart >= haystack.endIndex { break }
        }
        return nil
    }

    /// "Google Chrome" -> "gc", "deepseek-harness" -> "dh", "README.md" -> "rm".
    static func initials(of text: String) -> String {
        var result = ""
        var previousWasSeparator = true
        var previousCharacter: Character?
        for character in text {
            if !character.isLetter && !character.isNumber {
                previousWasSeparator = true
                previousCharacter = character
                continue
            }
            let startsNewWord = previousWasSeparator
                || (character.isUppercase && (previousCharacter?.isLowercase ?? false))
            if startsNewWord { result.append(character) }
            previousWasSeparator = false
            previousCharacter = character
        }
        return result
    }
}
