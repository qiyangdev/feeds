import DefuddleKit
import Foundation

enum ArticleContentExtractionError: LocalizedError {
    case missingURL
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .missingURL:
            "This article does not have a web address to extract."
        case .emptyContent:
            "No article content could be extracted from this webpage."
        }
    }
}

enum ArticleContentExtractor {
    private static let defuddle = Defuddle(
        configuration: DefuddleConfiguration(
            timeout: 30,
            allowsNetworkFallback: false
        )
    )

    static func extractMarkdown(from url: URL?) async throws -> String {
        guard let url else {
            throw ArticleContentExtractionError.missingURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Feeds/1.0 RSS Reader", forHTTPHeaderField: "User-Agent")

        let result: DefuddleResult
        do {
            result = try await defuddle.parse(
                request: request,
                options: DefuddleOptions(markdown: true)
            )
        } catch DefuddleError.cancelled {
            throw CancellationError()
        }
        let markdown = result.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !markdown.isEmpty else {
            throw ArticleContentExtractionError.emptyContent
        }
        return markdown
    }
}
