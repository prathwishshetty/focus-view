import Foundation
import Testing
@testable import FocusCore

@Suite struct BrowsingHistoryTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func recordsNewestFirstAndCountsRevisits() {
        var history = BrowsingHistory()
        history.recordVisit(to: URL(string: "https://a.com")!, title: "A", at: start)
        history.recordVisit(to: URL(string: "https://b.com")!, title: "B", at: start + 60)
        history.recordVisit(to: URL(string: "https://a.com#section")!, title: "", at: start + 120)

        #expect(history.entries.map(\.url) == ["https://a.com", "https://b.com"])
        #expect(history.entries[0].visitCount == 2)
        #expect(history.entries[0].title == "A")
    }

    @Test func quickRepeatsAreOneVisit() {
        var history = BrowsingHistory()
        history.recordVisit(to: URL(string: "https://a.com")!, title: "A", at: start)
        history.recordVisit(to: URL(string: "https://a.com")!, title: "A2", at: start + 1)
        #expect(history.entries.count == 1)
        #expect(history.entries[0].visitCount == 1)
        #expect(history.entries[0].title == "A2")
    }

    @Test func ignoresNonWebAddresses() {
        var history = BrowsingHistory()
        let recordedBlank = history.recordVisit(to: URL(string: "about:blank")!, title: "", at: start)
        let recordedFile = history.recordVisit(to: URL(fileURLWithPath: "/tmp/x.html"), title: "", at: start)
        #expect(!recordedBlank)
        #expect(!recordedFile)
        #expect(history.entries.isEmpty)
    }

    @Test func dropsOldestBeyondLimit() {
        var history = BrowsingHistory(limit: 2)
        for (offset, host) in ["a", "b", "c"].enumerated() {
            history.recordVisit(to: URL(string: "https://\(host).com")!, title: host, at: start + Double(offset) * 60)
        }
        #expect(history.entries.map(\.title) == ["c", "b"])
    }

    @Test func updatesTitles() {
        var history = BrowsingHistory()
        history.recordVisit(to: URL(string: "https://a.com/page")!, title: "", at: start)
        history.updateTitle("Page", for: URL(string: "https://a.com/page")!)
        #expect(history.entries[0].title == "Page")
    }

    var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func keepsTheLatestVisitOfEachDay() {
        var history = BrowsingHistory()
        let a = URL(string: "https://a.com")!
        history.recordVisit(to: a, title: "A", at: start, calendar: utc)
        history.recordVisit(to: a, title: "A", at: start + 600, calendar: utc)
        history.recordVisit(to: a, title: "A", at: start + 86_400, calendar: utc)

        #expect(history.entries[0].visits == [start + 86_400, start + 600])
        #expect(history.entries[0].visitCount == 3)
    }

    @Test func listsVisitsNewestFirst() {
        var history = BrowsingHistory()
        history.recordVisit(to: URL(string: "https://a.com")!, title: "A", at: start, calendar: utc)
        history.recordVisit(to: URL(string: "https://b.com")!, title: "B", at: start + 60, calendar: utc)
        history.recordVisit(to: URL(string: "https://a.com")!, title: "A", at: start + 86_400, calendar: utc)

        #expect(history.visits.map(\.title) == ["A", "B", "A"])
        #expect(history.visits.map(\.date) == [start + 86_400, start + 60, start])
    }

    @Test func removingOneDayKeepsTheOthers() {
        var history = BrowsingHistory()
        history.recordVisit(to: URL(string: "https://a.com")!, title: "A", at: start, calendar: utc)
        history.recordVisit(to: URL(string: "https://b.com")!, title: "B", at: start + 60, calendar: utc)
        history.recordVisit(to: URL(string: "https://a.com")!, title: "A", at: start + 86_400, calendar: utc)

        history.removeVisit(to: "https://a.com", onSameDayAs: start + 86_400 + 30, calendar: utc)
        #expect(history.entries.map(\.url) == ["https://b.com", "https://a.com"])
        #expect(history.entries[1].visits == [start])
        #expect(history.entries[1].lastVisited == start)

        history.removeVisit(to: "https://a.com", onSameDayAs: start, calendar: utc)
        #expect(history.entries.map(\.url) == ["https://b.com"])
    }

    @Test func readsHistorySavedWithoutVisits() throws {
        let json = #"{"limit":5000,"entries":[{"url":"https://a.com","title":"A","visitCount":2,"lastVisited":800000000}]}"#
        let history = try JSONDecoder().decode(BrowsingHistory.self, from: Data(json.utf8))
        #expect(history.entries[0].visits == [start])
        #expect(history.visits.map(\.url) == ["https://a.com"])
    }
}

@Suite struct SuggestionMatcherTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var candidates: [SuggestionCandidate] {
        [
            SuggestionCandidate(url: "https://github.com/", title: "GitHub", visitCount: 12, lastVisited: now - 3600),
            SuggestionCandidate(url: "https://github.com/apple/swift", title: "apple/swift: The Swift Programming Language", visitCount: 3, lastVisited: now - 7200),
            SuggestionCandidate(url: "https://news.ycombinator.com/", title: "Hacker News", visitCount: 30, lastVisited: now - 600),
            SuggestionCandidate(url: "https://www.wikipedia.org/", title: "Wikipedia", isFavorite: true),
            SuggestionCandidate(url: "https://developer.apple.com/documentation/webkit", title: "WebKit | Apple Developer Documentation", visitCount: 1, lastVisited: now - 40 * 86_400),
        ]
    }

    @Test func hostPrefixIsATopHit() {
        let matches = SuggestionMatcher.matches(for: "git", in: candidates, limit: 5, now: now)
        #expect(matches.first?.candidate.url == "https://github.com/")
        #expect(matches.first?.isPrefixMatch == true)
    }

    @Test func ignoresSchemeAndWWW() {
        let matches = SuggestionMatcher.matches(for: "https://www.wiki", in: candidates, limit: 5, now: now)
        #expect(matches.first?.candidate.title == "Wikipedia")
        #expect(matches.first?.isPrefixMatch == true)
    }

    @Test func matchesTitleWords() {
        let matches = SuggestionMatcher.matches(for: "hacker", in: candidates, limit: 5, now: now)
        #expect(matches.map(\.candidate.title) == ["Hacker News"])
        #expect(matches.first?.isPrefixMatch == false)
    }

    @Test func everyWordMustMatch() {
        let matches = SuggestionMatcher.matches(for: "swift programming", in: candidates, limit: 5, now: now)
        #expect(matches.map(\.candidate.url) == ["https://github.com/apple/swift"])
        #expect(SuggestionMatcher.matches(for: "swift cooking", in: candidates, limit: 5, now: now).isEmpty)
    }

    @Test func shortFragmentsMustStartAWord() {
        // "it" appears inside "github" but starts no word.
        #expect(SuggestionMatcher.matches(for: "it", in: candidates, limit: 5, now: now).isEmpty)
    }

    @Test func mergesDuplicatesAndKeepsFavoriteFlag() {
        let both = [
            SuggestionCandidate(url: "https://www.wikipedia.org/", title: "Wikipedia", visitCount: 2, lastVisited: now),
            SuggestionCandidate(url: "https://wikipedia.org", title: "Wikipedia", isFavorite: true),
        ]
        let matches = SuggestionMatcher.matches(for: "wik", in: both, limit: 5, now: now)
        #expect(matches.count == 1)
        #expect(matches.first?.candidate.isFavorite == true)
    }

    @Test func respectsLimitAndEmptyQuery() {
        #expect(SuggestionMatcher.matches(for: "a", in: candidates, limit: 1, now: now).count == 1)
        #expect(SuggestionMatcher.matches(for: "  ", in: candidates, limit: 5, now: now).isEmpty)
    }
}

@Suite struct SearchSuggestionTests {
    @Test func parsesOpenSearchJSON() {
        let data = Data(#"["swi",["swift","swift ui","Swift","",42]]"#.utf8)
        #expect(SearchSuggestionParser.parse(data) == ["swift", "swift ui"])
    }

    @Test func toleratesGarbage() {
        #expect(SearchSuggestionParser.parse(Data("not json".utf8)).isEmpty)
        #expect(SearchSuggestionParser.parse(Data(#"{"a":1}"#.utf8)).isEmpty)
    }

    @Test func buildsEscapedSuggestionURLs() {
        let url = SearchEngine.duckDuckGo.suggestionsURL(for: "c++ & more")
        #expect(url?.absoluteString == "https://duckduckgo.com/ac/?type=list&q=c%2B%2B%20%26%20more")
        #expect(SearchEngine.google.suggestionsURL(for: "x")?.host == "suggestqueries.google.com")
    }

    @Test(arguments: [
        ("apple.com", true),
        ("localhost:3000", true),
        ("https://example.com", true),
        ("swift concurrency", false),
        ("hello", false),
    ])
    func detectsAddresses(input: String, isAddress: Bool) {
        #expect(AddressResolver.isAddress(input) == isAddress)
    }
}

@Suite struct FuzzyMatcherTests {
    @Test func requiresCharactersInOrder() {
        #expect(FuzzyMatcher.score("spr", in: "Split Right") != nil)
        #expect(FuzzyMatcher.score("rps", in: "Split Right") == nil)
        #expect(FuzzyMatcher.score("xyz", in: "Split Right") == nil)
    }

    @Test func prefersWordStarts() {
        let wordStarts = FuzzyMatcher.score("sr", in: "Split Right")
        let midWord = FuzzyMatcher.score("sr", in: "Restore Size")
        #expect(wordStarts != nil && midWord != nil)
        #expect((wordStarts ?? 0) > (midWord ?? 0))
    }

    @Test func ignoresCaseAndSpaces() {
        #expect(FuzzyMatcher.score("SPLIT r", in: "split right") != nil)
        #expect(FuzzyMatcher.score("", in: "anything") == 0)
    }
}
