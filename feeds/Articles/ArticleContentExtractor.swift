import DefuddleKit
import Foundation

nonisolated enum ArticleContentExtractionError: LocalizedError, Sendable {
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

nonisolated enum ArticleContentExtractor {
    private static let defuddle = Defuddle(
        configuration: DefuddleConfiguration(
            timeout: 30,
            allowsNetworkFallback: false
        )
    )

    @concurrent
    static func extractMarkdown(from url: URL?) async throws -> String {
        guard let url else {
            throw ArticleContentExtractionError.missingURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(
            "Feeds/1.0 RSS Reader",
            forHTTPHeaderField: "User-Agent"
        )

        let result: DefuddleResult
        do {
            result = try await defuddle.parse(
                request: request,
                options: DefuddleOptions(markdown: true)
            )
        } catch DefuddleError.cancelled {
            throw CancellationError()
        }
        return try validatedMarkdown(from: result)
    }

    @concurrent
    static func extractMarkdown(
        fromHTML html: String,
        baseURL: URL?
    ) async throws -> String {
        let result: DefuddleResult
        do {
            result = try await defuddle.parse(
                html: html,
                baseURL: baseURL,
                options: DefuddleOptions(markdown: true)
            )
        } catch DefuddleError.cancelled {
            throw CancellationError()
        }
        return try validatedMarkdown(from: result)
    }

    private static func validatedMarkdown(
        from result: DefuddleResult
    ) throws -> String {
        let markdown = result.content.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !markdown.isEmpty else {
            throw ArticleContentExtractionError.emptyContent
        }
        return markdown
    }
}
