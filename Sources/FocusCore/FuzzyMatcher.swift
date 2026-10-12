/// Loose matching for the command palette: "spr" finds "Split Right".
public enum FuzzyMatcher {
    /// Scores how well `query` matches `candidate`, or nil if the query's
    /// characters don't all appear in it, in order. Spaces in the query are
    /// ignored. Higher is better: matches at the start of words, runs of
    /// consecutive characters, and shorter candidates score more.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate.lowercased())
        guard haystack.count >= needle.count else { return nil }

        var score = 0
        var matched = 0
        var previous: Int?
        for (index, character) in haystack.enumerated() where matched < needle.count {
            guard character == needle[matched] else { continue }
            var points = 1
            let startsWord = index == 0 || !(haystack[index - 1].isLetter || haystack[index - 1].isNumber)
            if startsWord { points += 8 }
            if index == 0 { points += 4 }
            if let previous, previous == index - 1 { points += 6 }
            score += points
            previous = index
            matched += 1
        }
        guard matched == needle.count else { return nil }
        return score - (haystack.count - needle.count) / 8
    }
}
