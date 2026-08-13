import Foundation

struct ParsedFeed: Equatable {
    var title: String
    var siteURL: String?
    var summary: String
    var entries: [ParsedEntry]
}

struct ParsedEntry: Equatable {
    var id: String
    var title: String
    var url: String?
    var summary: String
    var author: String?
    var publishedAt: Date
}

enum FeedParserError: LocalizedError {
    case invalidDocument
    case emptyFeed

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            "This feed could not be parsed."
        case .emptyFeed:
            "No recognizable articles were found in this feed."
        }
    }
}

final class FeedParser: NSObject, XMLParserDelegate {
    private struct EntryBuilder {
        var id = ""
        var title = ""
        var url: String?
        var summary = ""
        var author: String?
        var publishedAt: Date?
    }

    private var feedTitle = ""
    private var feedURL: String?
    private var feedSummary = ""
    private var entries: [ParsedEntry] = []
    private var entry: EntryBuilder?
    private var textStack: [String] = []
    private var parseError: Error?

    private var text: String {
        get { textStack.last ?? "" }
        set {
            guard !textStack.isEmpty else { return }
            textStack[textStack.count - 1] = newValue
        }
    }

    func parse(_ data: Data) throws -> ParsedFeed {
        reset()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = false

        guard parser.parse(), parseError == nil else {
            throw parseError ?? parser.parserError ?? FeedParserError.invalidDocument
        }
        guard !entries.isEmpty else { throw FeedParserError.emptyFeed }

        return ParsedFeed(
            title: feedTitle.cleanedText.ifEmpty("Untitled Feed"),
            siteURL: feedURL,
            summary: feedSummary.cleanedHTML,
            entries: entries
        )
    }

    private func reset() {
        feedTitle = ""
        feedURL = nil
        feedSummary = ""
        entries = []
        entry = nil
        textStack = []
        parseError = nil
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = elementName.lowercased()
        textStack.append("")

        if name == "item" || name == "entry" {
            entry = EntryBuilder()
        }

        guard name == "link", let href = attributeDict["href"] else { return }
        let relationship = attributeDict["rel"]?.lowercased() ?? "alternate"
        guard relationship == "alternate" || relationship.isEmpty else { return }

        if entry != nil {
            entry?.url = href
        } else if feedURL == nil {
            feedURL = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in textStack.indices {
            textStack[index] += string
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        let string = String(data: CDATABlock, encoding: .utf8) ?? ""
        for index in textStack.indices {
            textStack[index] += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let value = text.cleanedText
        defer {
            if !textStack.isEmpty {
                textStack.removeLast()
            }
        }

        if var current = entry {
            switch name {
            case "title":
                current.title = value
            case "link":
                if current.url == nil, !value.isEmpty { current.url = value }
            case "guid", "id":
                current.id = value
            case "description", "summary", "content", "content:encoded", "encoded":
                if !value.isEmpty { current.summary = text.cleanedHTML }
            case "author", "dc:creator", "creator", "name":
                if current.author == nil, !value.isEmpty { current.author = value }
            case "pubdate", "published", "updated", "dc:date":
                current.publishedAt = FeedDateParser.date(from: value)
            case "item", "entry":
                let fallbackID = current.url ?? "\(current.title)|\(current.publishedAt?.timeIntervalSince1970 ?? 0)"
                entries.append(
                    ParsedEntry(
                        id: current.id.ifEmpty(fallbackID),
                        title: current.title.ifEmpty("Untitled"),
                        url: current.url,
                        summary: current.summary,
                        author: current.author,
                        publishedAt: current.publishedAt ?? .now
                    )
                )
                entry = nil
                return
            default:
                break
            }
            entry = current
        } else {
            switch name {
            case "title":
                if feedTitle.isEmpty { feedTitle = value }
            case "link":
                if feedURL == nil, !value.isEmpty { feedURL = value }
            case "description", "subtitle":
                if feedSummary.isEmpty { feedSummary = text }
            default:
                break
            }
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }
}

private enum FeedDateParser {
    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "yyyy-MM-dd'T'HH:mm:ssZ",
        "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
    ]

    static func date(from value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

private extension String {
    var cleanedText: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var cleanedHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .cleanedText
    }

    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
