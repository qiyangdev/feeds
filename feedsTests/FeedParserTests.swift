import Foundation
import Testing
@testable import feeds

struct FeedParserTests {
    @Test func feedDoesNotAutomaticallyExtractContentByDefault() {
        let feed = Feed(feedURLString: "https://example.com/feed.xml", title: "Example")

        #expect(!feed.automaticallyExtractsArticleContent)
    }

    @Test func feedCanEnableAutomaticContentExtraction() {
        let feed = Feed(
            feedURLString: "https://example.com/feed.xml",
            title: "Example",
            automaticallyExtractsArticleContent: true
        )

        #expect(feed.automaticallyExtractsArticleContent)
    }

    @Test func parsesRSS() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Example RSS</title><link>https://example.com</link>
          <item><title>First post</title><link>https://example.com/first</link>
          <guid>post-1</guid><pubDate>Tue, 12 Aug 2026 08:30:00 +0000</pubDate>
          <description><![CDATA[<p>Hello <strong>RSS</strong>.</p>]]></description></item>
        </channel></rss>
        """

        let result = try FeedParser().parse(Data(xml.utf8))

        #expect(result.title == "Example RSS")
        #expect(result.siteURL == "https://example.com")
        #expect(result.entries.count == 1)
        #expect(result.entries[0].id == "post-1")
        #expect(result.entries[0].summary == "Hello RSS .")
    }

    @Test func parsesAtom() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Example Atom</title><link href="https://example.com"/>
          <entry><title>Atom post</title><id>tag:example.com,2026:1</id>
          <link href="https://example.com/atom"/><updated>2026-08-12T08:30:00Z</updated>
          <summary>Short summary</summary></entry>
        </feed>
        """

        let result = try FeedParser().parse(Data(xml.utf8))

        #expect(result.title == "Example Atom")
        #expect(result.entries.first?.url == "https://example.com/atom")
        #expect(result.entries.first?.summary == "Short summary")
    }

    @Test func preservesTextInsideNestedXMLContent() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel>
          <title>Nested Content</title>
          <item>
            <guid>nested-entry</guid>
            <title>A nested summary</title>
            <description>
              <p>Lead <strong>bold <em>and nested</em></strong> tail.</p>
            </description>
          </item>
        </channel></rss>
        """

        let result = try FeedParser().parse(Data(xml.utf8))

        #expect(result.entries.count == 1)
        #expect(result.entries[0].summary == "Lead bold and nested tail.")
    }

    @Test func findsRelativeFeedIcon() throws {
        let html = """
        <html><head>
          <link rel="apple-touch-icon" href="/assets/icon.png">
          <link href='/favicon.ico' rel='shortcut icon'>
        </head></html>
        """
        let pageURL = try #require(URL(string: "https://example.com/posts/latest"))

        let urls = FeedIconService.candidateURLs(in: html, relativeTo: pageURL)

        #expect(urls.map(\.absoluteString) == [
            "https://example.com/assets/icon.png",
            "https://example.com/favicon.ico"
        ])
    }
}
