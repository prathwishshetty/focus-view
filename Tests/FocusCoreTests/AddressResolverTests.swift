import Foundation
import Testing
@testable import FocusCore

@Suite struct AddressResolverTests {
    @Test(arguments: [
        ("apple.com", "https://apple.com"),
        ("www.apple.com/mac", "https://www.apple.com/mac"),
        ("https://example.com/a?b=c", "https://example.com/a?b=c"),
        ("http://example.com", "http://example.com"),
        ("localhost:3000", "http://localhost:3000"),
        ("localhost", "http://localhost"),
        ("192.168.1.10:8080/admin", "http://192.168.1.10:8080/admin"),
        ("printer.local", "http://printer.local"),
        ("about:blank", "about:blank"),
        ("  github.com/anthropics  ", "https://github.com/anthropics"),
        ("user@example.com", "https://user@example.com"),
    ])
    func resolvesAddresses(input: String, expected: String) {
        #expect(AddressResolver.resolve(input)?.absoluteString == expected)
    }

    @Test(arguments: [
        "swift concurrency",
        "hello",
        "what is 1.5",
        "c++ tutorials",
        "localhost:abc",
    ])
    func searchesEverythingElse(input: String) {
        let url = AddressResolver.resolve(input)
        #expect(url?.host == "www.google.com")
        #expect(url?.path == "/search")
    }

    @Test func emptyInputResolvesToNothing() {
        #expect(AddressResolver.resolve("   ") == nil)
    }

    @Test func queriesAreFullyEscaped() {
        let url = SearchEngine.google.searchURL(for: "c++ & more")
        #expect(url.absoluteString == "https://www.google.com/search?q=c%2B%2B%20%26%20more")
    }

    @Test func otherEnginesWork() {
        #expect(AddressResolver.resolve("swift", engine: .duckDuckGo)?.absoluteString == "https://duckduckgo.com/?q=swift")
    }

    @Test func formatsHosts() {
        #expect(AddressFormatter.displayHost(for: URL(string: "https://www.apple.com/mac/")!) == "apple.com")
        #expect(AddressFormatter.displayHost(for: URL(string: "https://news.ycombinator.com")!) == "news.ycombinator.com")
        #expect(AddressFormatter.editableString(for: URL(string: "about:blank")) == "")
    }
}
