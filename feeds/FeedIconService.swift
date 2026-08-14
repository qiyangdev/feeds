import CryptoKit
import Foundation
import ImageIO

nonisolated enum FeedIconService {
    private static let maximumIconSize = 2_000_000
    private static let thumbnailPixelSize = 64
    private static let thumbnailCache = ThumbnailCache(maximumEntryCount: 128)

    @concurrent
    static func fetchIconData(siteURLString: String?, feedURL: URL) async
        -> Data?
    {
        let siteURL =
            normalizedSiteURL(siteURLString) ?? originURL(for: feedURL)
        guard let siteURL else { return nil }

        var candidates: [URL] = []
        if let html = await fetchHTML(from: siteURL) {
            candidates.append(
                contentsOf: candidateURLs(in: html, relativeTo: siteURL)
            )
        }
        if let fallback = URL(string: "/favicon.ico", relativeTo: siteURL)?
            .absoluteURL
        {
            candidates.append(fallback)
        }

        var visited = Set<URL>()
        for url in candidates where visited.insert(url).inserted {
            if let data = await fetchImage(from: url) { return data }
        }
        return nil
    }

    @concurrent
    static func thumbnail(from data: Data?) async -> CGImage? {
        guard let data, !data.isEmpty else { return nil }
        return await thumbnailCache.thumbnail(
            for: data,
            maximumPixelSize: thumbnailPixelSize
        )
    }

    static func candidateURLs(in html: String, relativeTo pageURL: URL) -> [URL]
    {
        let tagPattern = #"<link\b[^>]*>"#
        guard
            let tagExpression = try? NSRegularExpression(
                pattern: tagPattern,
                options: .caseInsensitive
            )
        else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return tagExpression.matches(in: html, range: range).compactMap {
            match in
            guard let tagRange = Range(match.range, in: html) else {
                return nil
            }
            let attributes = attributes(in: String(html[tagRange]))
            guard
                let relationship = attributes["rel"]?.lowercased(),
                relationship.split(whereSeparator: \Character.isWhitespace)
                    .contains(where: { $0.contains("icon") }),
                let href = attributes["href"],
                !href.lowercased().hasPrefix("data:")
            else {
                return nil
            }
            return URL(
                string: href.replacingOccurrences(of: "&amp;", with: "&"),
                relativeTo: pageURL
            )?.absoluteURL
        }
    }

    private static func attributes(in tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*([\"'])(.*?)\2"#
        guard
            let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
        else {
            return [:]
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        return expression.matches(in: tag, range: range).reduce(into: [:]) {
            result,
            match in
            guard
                let nameRange = Range(match.range(at: 1), in: tag),
                let valueRange = Range(match.range(at: 3), in: tag)
            else {
                return
            }
            result[String(tag[nameRange]).lowercased()] = String(
                tag[valueRange]
            )
        }
    }

    private static func normalizedSiteURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value) else { return nil }
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    private static func originURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        return components.url
    }

    private static func fetchHTML(from url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Feeds/1.0 RSS Reader",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "text/html, application/xhtml+xml",
            forHTTPHeaderField: "Accept"
        )

        guard
            let (data, response) = try? await URLSession.shared.data(
                for: request
            ),
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            data.count <= 2_000_000
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func fetchImage(from url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "Feeds/1.0 RSS Reader",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        guard
            let (data, response) = try? await URLSession.shared.data(
                for: request
            ),
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            !data.isEmpty,
            data.count <= maximumIconSize,
            CGImageSourceCreateWithData(data as CFData, nil) != nil
        else {
            return nil
        }
        return data
    }

    private static func makeThumbnail(
        from data: Data,
        maximumPixelSize: Int
    ) -> CGImage? {
        let sourceOptions =
            [
                kCGImageSourceShouldCache: false
            ] as CFDictionary
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                sourceOptions
            )
        else {
            return nil
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        )
    }

    private actor ThumbnailCache {
        private nonisolated struct Key: Hashable, Sendable {
            let digest: SHA256.Digest
            let maximumPixelSize: Int
        }

        private let maximumEntryCount: Int
        private var images: [Key: CGImage] = [:]
        private var recency: [Key] = []

        init(maximumEntryCount: Int) {
            self.maximumEntryCount = max(1, maximumEntryCount)
        }

        func thumbnail(
            for data: Data,
            maximumPixelSize: Int
        ) -> CGImage? {
            let key = Key(
                digest: SHA256.hash(data: data),
                maximumPixelSize: maximumPixelSize
            )
            if let image = images[key] {
                markAsRecentlyUsed(key)
                return image
            }

            guard !Task.isCancelled,
                let image = FeedIconService.makeThumbnail(
                    from: data,
                    maximumPixelSize: maximumPixelSize
                )
            else {
                return nil
            }

            images[key] = image
            markAsRecentlyUsed(key)
            discardOldestImageIfNeeded()
            return image
        }

        private func markAsRecentlyUsed(_ key: Key) {
            recency.removeAll { $0 == key }
            recency.append(key)
        }

        private func discardOldestImageIfNeeded() {
            guard images.count > maximumEntryCount,
                let oldestKey = recency.first
            else {
                return
            }
            recency.removeFirst()
            images.removeValue(forKey: oldestKey)
        }
    }
}
