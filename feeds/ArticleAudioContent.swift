import Foundation

nonisolated struct ArticleAudioSource: Equatable, Hashable, Sendable {
  let url: URL
  let mimeType: String?
}

nonisolated struct ArticleAudioDescriptor: Equatable, Hashable, Sendable {
  let id: String
  let label: String?
  let sources: [ArticleAudioSource]
}

nonisolated struct ArticleAudioDocument: Equatable, Sendable {
  let markdown: String
  let audio: [ArticleAudioDescriptor]
}

/// Extracts standalone HTML audio elements without parsing Markdown-looking text in code.
///
/// The scanner deliberately recognizes only `<audio>` elements beginning in column zero. This
/// conservative boundary keeps removal from changing the structure of paragraphs, lists, quotes,
/// or other Markdown containers. Ambiguous or malformed input is left untouched.
nonisolated enum ArticleAudioContentParser {
  static let maximumInputByteCount = 2 * 1_024 * 1_024
  static let maximumAudioCount = 32
  static let maximumSourceCount = 8
  static let maximumURLByteCount = 2_048
  static let maximumLabelCharacterCount = 256

  @concurrent
  static func parse(
    from markdown: String,
    baseURL: URL?
  ) async -> ArticleAudioDocument {
    guard !Task.isCancelled else {
      return ArticleAudioDocument(markdown: markdown, audio: [])
    }
    return parseSynchronously(from: markdown, baseURL: baseURL)
  }

  static func parseSynchronously(
    from markdown: String,
    baseURL: URL?
  ) -> ArticleAudioDocument {
    parseSynchronouslyWithDiagnostics(
      from: markdown,
      baseURL: baseURL
    ).document
  }

  /// Exposes deterministic scanner work for complexity regression tests. The counter measures
  /// byte visits made by the Markdown and HTML scanners, rather than elapsed wall-clock time.
  static func parseSynchronouslyWithDiagnostics(
    from markdown: String,
    baseURL: URL?
  ) -> (document: ArticleAudioDocument, visitedByteCount: Int) {
    guard markdown.utf8.count <= maximumInputByteCount else {
      return (
        ArticleAudioDocument(markdown: markdown, audio: []),
        0
      )
    }

    let bytes = Array(markdown.utf8)
    var metrics = ScanMetrics()
    var scanner = Scanner(
      bytes: bytes,
      baseURL: baseURL,
      metrics: metrics
    )
    let document = scanner.scan()
    metrics = scanner.metrics
    return (document, metrics.byteVisits)
  }
}

nonisolated extension ArticleAudioContentParser {
  fileprivate struct ScanMetrics {
    var byteVisits = 0

    mutating func visit(_ count: Int = 1) {
      byteVisits += count
    }
  }

  fileprivate struct Fence {
    let marker: UInt8
    let length: Int
    let rangeStart: Int
  }

  fileprivate struct BacktickRun {
    let start: Int
    let end: Int
    let length: Int
    let isEscaped: Bool
  }

  fileprivate enum RawElement: CaseIterable {
    case code
    case pre
    case script
    case style
    case textarea

    var name: StaticString {
      switch self {
      case .code: "code"
      case .pre: "pre"
      case .script: "script"
      case .style: "style"
      case .textarea: "textarea"
      }
    }
  }

  fileprivate enum ElementName: Equatable {
    case audio
    case source
  }

  fileprivate enum AttributeKey {
    case source
    case mimeType
    case title
    case accessibilityLabel
  }

  fileprivate struct RelevantAttributes {
    var source: Range<Int>?
    var mimeType: Range<Int>?
    var title: Range<Int>?
    var accessibilityLabel: Range<Int>?

    subscript(key: AttributeKey) -> Range<Int>? {
      get {
        switch key {
        case .source: source
        case .mimeType: mimeType
        case .title: title
        case .accessibilityLabel: accessibilityLabel
        }
      }
      set {
        switch key {
        case .source: source = newValue
        case .mimeType: mimeType = newValue
        case .title: title = newValue
        case .accessibilityLabel: accessibilityLabel = newValue
        }
      }
    }
  }

  fileprivate struct HTMLTag {
    let range: Range<Int>
    let nameRange: Range<Int>
    let isClosing: Bool
    let isSelfClosing: Bool
  }

  fileprivate struct ParsedAudioElement {
    let range: Range<Int>
    let openingTag: HTMLTag
    let closingTag: HTMLTag?
    let label: String?
    let sources: [ArticleAudioSource]
  }

  fileprivate enum AudioScanResult {
    case element(ParsedAudioElement)
    case resume(at: Int)
    case stop
  }

  fileprivate struct Edit {
    let range: Range<Int>
    let replacement: [UInt8]
  }

  fileprivate nonisolated struct Scanner {
    let bytes: [UInt8]
    let baseURL: URL?
    var metrics: ScanMetrics

    mutating func scan() -> ArticleAudioDocument {
      guard !bytes.isEmpty else {
        return ArticleAudioDocument(markdown: "", audio: [])
      }

      let markdownBlockCode = markdownBlockCodeRanges()
      // Code spans take precedence over raw HTML. Recompute them after finding opaque
      // elements so backticks inside a real <code>/<pre> region cannot leak out of it.
      let preliminaryInlineCode = inlineCodeRanges(
        excluding: markdownBlockCode
      )
      let htmlOpaque = htmlOpaqueRanges(
        excluding: merge(markdownBlockCode, preliminaryInlineCode)
      )
      let blockProtected = merge(markdownBlockCode, htmlOpaque)
      let inlineCode = inlineCodeRanges(excluding: blockProtected)
      let protected = merge(blockProtected, inlineCode)

      var descriptors: [ArticleAudioDescriptor] = []
      descriptors.reserveCapacity(
        ArticleAudioContentParser.maximumAudioCount
      )
      var edits: [Edit] = []
      edits.reserveCapacity(
        ArticleAudioContentParser.maximumAudioCount
      )

      var lineStart = 0
      var protectedIndex = 0
      var processedAudioCount = 0
      while lineStart < bytes.count {
        while protectedIndex < protected.count,
          protected[protectedIndex].upperBound <= lineStart
        {
          protectedIndex += 1
        }

        let line = lineBounds(startingAt: lineStart)
        let isProtected =
          protectedIndex < protected.count
          && protected[protectedIndex].contains(lineStart)
        guard !isProtected,
          let openingElement = elementName(at: lineStart),
          openingElement.0 == false,
          openingElement.1 == .audio
        else {
          lineStart = line.end
          continue
        }

        guard
          processedAudioCount
            < ArticleAudioContentParser.maximumAudioCount
        else {
          break
        }

        switch scanAudioElement(
          startingAt: lineStart,
          htmlOpaque: htmlOpaque
        ) {
        case .element(let element):
          processedAudioCount += 1
          if element.sources.isEmpty {
            edits.append(
              Edit(
                range: element.range,
                replacement: fallbackBytes(
                  for: element,
                  htmlOpaque: htmlOpaque
                )
              )
            )
          } else {
            let firstSource = element.sources[0]
            descriptors.append(
              ArticleAudioDescriptor(
                id: "audio-\(descriptors.count)-\(firstSource.url.absoluteString)",
                label: element.label,
                sources: element.sources
              )
            )
            edits.append(
              Edit(
                range: element.range,
                replacement: lineBreaks(
                  in: element.range
                )
              )
            )
          }
          lineStart = nextLineStart(after: element.range.upperBound)

        case .resume(let resumeIndex):
          lineStart = max(
            nextLineStart(after: lineStart),
            resumeIndex
          )

        case .stop:
          lineStart = bytes.count
        }
      }

      guard !edits.isEmpty else {
        return ArticleAudioDocument(
          markdown: String(decoding: bytes, as: UTF8.self),
          audio: descriptors
        )
      }
      return ArticleAudioDocument(
        markdown: String(
          decoding: applying(edits),
          as: UTF8.self
        ),
        audio: descriptors
      )
    }

    // MARK: Markdown protection

    mutating func markdownBlockCodeRanges() -> [Range<Int>] {
      var ranges: [Range<Int>] = []
      var lineStart = 0
      var fence: Fence?

      while lineStart < bytes.count {
        let line = lineBounds(startingAt: lineStart)
        if let currentFence = fence {
          if isClosingFence(
            in: line.content,
            fence: currentFence
          ) {
            appendMerged(
              currentFence.rangeStart..<line.end,
              to: &ranges
            )
            fence = nil
          }
        } else if let opening = openingFence(in: line.content) {
          fence = Fence(
            marker: opening.marker,
            length: opening.length,
            rangeStart: lineStart
          )
        } else if isIndentedCode(line.content) {
          appendMerged(lineStart..<line.end, to: &ranges)
        }
        lineStart = line.end
      }

      if let fence {
        appendMerged(fence.rangeStart..<bytes.count, to: &ranges)
      }
      return ranges
    }

    mutating func openingFence(
      in line: Range<Int>
    ) -> (marker: UInt8, length: Int)? {
      var index = line.lowerBound
      var indentation = 0
      while index < line.upperBound,
        bytes[index] == .space,
        indentation < 4
      {
        metrics.visit()
        indentation += 1
        index += 1
      }
      guard indentation <= 3, index < line.upperBound else {
        return nil
      }

      let marker = bytes[index]
      guard marker == .backtick || marker == .tilde else {
        metrics.visit()
        return nil
      }
      let runStart = index
      while index < line.upperBound, bytes[index] == marker {
        metrics.visit()
        index += 1
      }
      let length = index - runStart
      guard length >= 3 else { return nil }

      if marker == .backtick {
        var remainder = index
        while remainder < line.upperBound {
          metrics.visit()
          if bytes[remainder] == .backtick { return nil }
          remainder += 1
        }
      }
      return (marker, length)
    }

    mutating func isClosingFence(
      in line: Range<Int>,
      fence: Fence
    ) -> Bool {
      var index = line.lowerBound
      var indentation = 0
      while index < line.upperBound,
        bytes[index] == .space,
        indentation < 4
      {
        metrics.visit()
        indentation += 1
        index += 1
      }
      guard indentation <= 3 else { return false }

      let runStart = index
      while index < line.upperBound,
        bytes[index] == fence.marker
      {
        metrics.visit()
        index += 1
      }
      guard index - runStart >= fence.length else { return false }

      while index < line.upperBound {
        metrics.visit()
        guard bytes[index].isHorizontalWhitespace else {
          return false
        }
        index += 1
      }
      return true
    }

    mutating func isIndentedCode(_ line: Range<Int>) -> Bool {
      guard !line.isEmpty else { return false }
      if bytes[line.lowerBound] == .tab {
        metrics.visit()
        return true
      }

      var index = line.lowerBound
      var spaces = 0
      while index < line.upperBound,
        bytes[index] == .space,
        spaces < 4
      {
        metrics.visit()
        spaces += 1
        index += 1
      }
      return spaces == 4
    }

    mutating func inlineCodeRanges(
      excluding excluded: [Range<Int>]
    ) -> [Range<Int>] {
      var runs: [BacktickRun] = []
      var excludedIndex = 0
      var index = 0

      while index < bytes.count {
        while excludedIndex < excluded.count,
          excluded[excludedIndex].upperBound <= index
        {
          excludedIndex += 1
        }
        if excludedIndex < excluded.count,
          excluded[excludedIndex].contains(index)
        {
          index = excluded[excludedIndex].upperBound
          continue
        }

        metrics.visit()
        guard bytes[index] == .backtick else {
          index += 1
          continue
        }

        let start = index
        while index < bytes.count, bytes[index] == .backtick {
          metrics.visit()
          index += 1
        }
        var slashIndex = start
        var slashCount = 0
        while slashIndex > 0,
          bytes[slashIndex - 1] == .backslash
        {
          metrics.visit()
          slashIndex -= 1
          slashCount += 1
        }
        runs.append(
          BacktickRun(
            start: start,
            end: index,
            length: index - start,
            isEscaped: slashCount.isMultiple(of: 2) == false
          )
        )
      }

      var nextMatching = [Int?](
        repeating: nil,
        count: runs.count
      )
      var nearestByLength: [Int: Int] = [:]
      for runIndex in runs.indices.reversed() {
        nextMatching[runIndex] = nearestByLength[runs[runIndex].length]
        nearestByLength[runs[runIndex].length] = runIndex
      }

      var ranges: [Range<Int>] = []
      var runIndex = 0
      while runIndex < runs.count {
        let opener = runs[runIndex]
        guard !opener.isEscaped,
          let closingIndex = nextMatching[runIndex]
        else {
          runIndex += 1
          continue
        }
        let closer = runs[closingIndex]
        appendMerged(opener.start..<closer.end, to: &ranges)
        runIndex = closingIndex + 1
      }
      return ranges
    }

    // MARK: HTML opaque regions

    mutating func htmlOpaqueRanges(
      excluding excluded: [Range<Int>]
    ) -> [Range<Int>] {
      var ranges: [Range<Int>] = []
      var excludedIndex = 0
      var index = 0

      while index < bytes.count {
        while excludedIndex < excluded.count,
          excluded[excludedIndex].upperBound <= index
        {
          excludedIndex += 1
        }
        if excludedIndex < excluded.count,
          excluded[excludedIndex].contains(index)
        {
          index = excluded[excludedIndex].upperBound
          continue
        }

        metrics.visit()
        guard bytes[index] == .lessThan else {
          index += 1
          continue
        }

        if hasBytes("<!--", at: index) {
          let end = endOfComment(startingAt: index)
          appendMerged(index..<end, to: &ranges)
          index = end
          continue
        }

        guard let rawElement = rawOpeningElement(at: index) else {
          if let tag = scanTag(at: index) {
            index = tag.range.upperBound
          } else if isPlausibleTagStart(at: index) {
            // `scanTag` inspected the remainder looking for an unquoted `>`.
            // Stopping keeps malformed tag sequences linear instead of
            // rescanning the same suffix from every following `<`.
            appendMerged(index..<bytes.count, to: &ranges)
            break
          } else {
            index += 1
          }
          continue
        }
        guard let openingTag = scanTag(at: index) else {
          appendMerged(index..<bytes.count, to: &ranges)
          break
        }
        guard !openingTag.isClosing else {
          index += 1
          continue
        }

        let end: Int
        if openingTag.isSelfClosing {
          end = openingTag.range.upperBound
        } else {
          end = endOfRawElement(
            rawElement,
            after: openingTag.range.upperBound
          )
        }
        appendMerged(index..<end, to: &ranges)
        index = end
      }
      return ranges
    }

    mutating func endOfComment(startingAt start: Int) -> Int {
      var index = start + 4
      while index + 2 < bytes.count {
        metrics.visit()
        if bytes[index] == .hyphen,
          bytes[index + 1] == .hyphen,
          bytes[index + 2] == .greaterThan
        {
          return index + 3
        }
        index += 1
      }
      return bytes.count
    }

    mutating func rawOpeningElement(at index: Int) -> RawElement? {
      for element in RawElement.allCases {
        if tagNameEquals(
          element.name,
          at: index,
          closing: false
        ) {
          return element
        }
      }
      return nil
    }

    mutating func endOfRawElement(
      _ element: RawElement,
      after openingEnd: Int
    ) -> Int {
      var index = openingEnd
      while index < bytes.count {
        metrics.visit()
        guard bytes[index] == .lessThan else {
          index += 1
          continue
        }
        if hasBytes("<!--", at: index) {
          index = endOfComment(startingAt: index)
          continue
        }
        guard
          tagNameEquals(
            element.name,
            at: index,
            closing: true
          )
        else {
          index += 1
          continue
        }
        guard let closingTag = scanTag(at: index) else {
          return bytes.count
        }
        guard closingTag.isClosing,
          closingTagHasOnlyWhitespace(closingTag)
        else {
          index = closingTag.range.upperBound
          continue
        }
        return closingTag.range.upperBound
      }
      return bytes.count
    }

    // MARK: Audio extraction

    mutating func scanAudioElement(
      startingAt start: Int,
      htmlOpaque: [Range<Int>]
    ) -> AudioScanResult {
      guard let openingTag = scanTag(at: start),
        !openingTag.isClosing,
        name(of: openingTag) == .audio
      else {
        return .stop
      }

      let openingAttributes = attributes(in: openingTag)
      var sources: [ArticleAudioSource] = []
      sources.reserveCapacity(
        ArticleAudioContentParser.maximumSourceCount
      )
      var seenURLs: Set<String> = []
      appendSource(
        attributes: openingAttributes,
        seenURLs: &seenURLs,
        sources: &sources
      )
      let label = audioLabel(from: openingAttributes)

      if openingTag.isSelfClosing {
        guard
          hasOnlyHorizontalWhitespaceUntilLineEnd(
            from: openingTag.range.upperBound
          )
        else {
          return .resume(
            at: nextLineStart(
              after: openingTag.range.upperBound
            )
          )
        }
        return .element(
          ParsedAudioElement(
            range: openingTag.range,
            openingTag: openingTag,
            closingTag: nil,
            label: label,
            sources: sources
          )
        )
      }

      var opaqueIndex = 0
      while opaqueIndex < htmlOpaque.count,
        htmlOpaque[opaqueIndex].upperBound <= openingTag.range.upperBound
      {
        opaqueIndex += 1
      }

      var index = openingTag.range.upperBound
      while index < bytes.count {
        while opaqueIndex < htmlOpaque.count,
          htmlOpaque[opaqueIndex].upperBound <= index
        {
          opaqueIndex += 1
        }
        if opaqueIndex < htmlOpaque.count,
          htmlOpaque[opaqueIndex].contains(index)
        {
          index = htmlOpaque[opaqueIndex].upperBound
          continue
        }

        metrics.visit()
        guard bytes[index] == .lessThan else {
          index += 1
          continue
        }

        guard let tag = scanTag(at: index) else {
          index += 1
          continue
        }
        guard let identifiedName = name(of: tag) else {
          index = tag.range.upperBound
          continue
        }
        let identified = (tag.isClosing, identifiedName)

        if identified.0 == false,
          identified.1 == .audio,
          isLineStart(index)
        {
          return .resume(at: index)
        }

        switch identified {
        case (true, .audio):
          guard closingTagHasOnlyWhitespace(tag) else {
            index = tag.range.upperBound
            continue
          }
          guard
            hasOnlyHorizontalWhitespaceUntilLineEnd(
              from: tag.range.upperBound
            )
          else {
            return .resume(
              at: nextLineStart(
                after: tag.range.upperBound
              )
            )
          }
          return .element(
            ParsedAudioElement(
              range: start..<tag.range.upperBound,
              openingTag: openingTag,
              closingTag: tag,
              label: label,
              sources: sources
            )
          )

        case (false, .source):
          let sourceAttributes = attributes(in: tag)
          appendSource(
            attributes: sourceAttributes,
            seenURLs: &seenURLs,
            sources: &sources
          )
          index = tag.range.upperBound

        default:
          index = tag.range.upperBound
        }
      }
      return .stop
    }

    mutating func appendSource(
      attributes: RelevantAttributes,
      seenURLs: inout Set<String>,
      sources: inout [ArticleAudioSource]
    ) {
      guard let sourceRange = attributes.source else { return }
      guard
        sources.count
          < ArticleAudioContentParser.maximumSourceCount
      else {
        return
      }

      guard
        sourceRange.count
          <= ArticleAudioContentParser.maximumURLByteCount,
        let url = safeMediaURL(from: sourceRange),
        seenURLs.insert(url.absoluteString).inserted
      else {
        return
      }

      let mimeType: String?
      if let range = attributes.mimeType, range.count <= 256 {
        let normalized = decodeHTMLEntities(range)
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased()
        mimeType = normalized.isEmpty ? nil : normalized
      } else {
        mimeType = nil
      }
      sources.append(
        ArticleAudioSource(url: url, mimeType: mimeType)
      )
    }

    mutating func audioLabel(
      from attributes: RelevantAttributes
    ) -> String? {
      guard
        let range = attributes.accessibilityLabel
          ?? attributes.title
      else {
        return nil
      }
      let decoded = decodeHTMLEntities(range)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !decoded.isEmpty else { return nil }
      return String(
        decoded.prefix(
          ArticleAudioContentParser.maximumLabelCharacterCount
        )
      )
    }

    mutating func safeMediaURL(from range: Range<Int>) -> URL? {
      let value = decodeHTMLEntities(range)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty,
        value.utf8.count
          <= ArticleAudioContentParser.maximumURLByteCount,
        let absoluteURL = URL(string: value, relativeTo: baseURL)?
          .absoluteURL,
        var components = URLComponents(
          url: absoluteURL,
          resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        let host = components.host,
        !host.isEmpty,
        components.user == nil,
        components.password == nil
      else {
        return nil
      }

      components.scheme = scheme
      components.host = host.lowercased()
      components.fragment = nil
      if (scheme == "https" && components.port == 443)
        || (scheme == "http" && components.port == 80)
      {
        components.port = nil
      }
      guard let result = components.url,
        result.absoluteString.utf8.count
          <= ArticleAudioContentParser.maximumURLByteCount
      else {
        return nil
      }
      return result
    }

    // MARK: HTML tokenization

    mutating func scanTag(at start: Int) -> HTMLTag? {
      guard start < bytes.count, bytes[start] == .lessThan else {
        return nil
      }
      var index = start + 1
      var isClosing = false
      if index < bytes.count, bytes[index] == .slash {
        isClosing = true
        index += 1
      }

      let nameStart = index
      while index < bytes.count, bytes[index].isTagNameByte {
        metrics.visit()
        index += 1
      }
      guard index > nameStart,
        index == bytes.count
          || bytes[index].isTagNameBoundary
      else {
        return nil
      }

      var quote: UInt8?
      while index < bytes.count {
        metrics.visit()
        let byte = bytes[index]
        if let activeQuote = quote {
          if byte == activeQuote { quote = nil }
        } else if byte == .singleQuote || byte == .doubleQuote {
          quote = byte
        } else if byte == .greaterThan {
          var slashIndex = index
          while slashIndex > nameStart,
            bytes[slashIndex - 1].isHorizontalWhitespace
          {
            slashIndex -= 1
          }
          return HTMLTag(
            range: start..<(index + 1),
            nameRange: nameStart..<tagNameEnd(from: nameStart),
            isClosing: isClosing,
            isSelfClosing: slashIndex > nameStart
              && bytes[slashIndex - 1] == .slash
          )
        }
        index += 1
      }
      return nil
    }

    func tagNameEnd(from start: Int) -> Int {
      var index = start
      while index < bytes.count, bytes[index].isTagNameByte {
        index += 1
      }
      return index
    }

    mutating func attributes(
      in tag: HTMLTag
    ) -> RelevantAttributes {
      var result = RelevantAttributes()
      var index = tag.nameRange.upperBound
      let end = tag.range.upperBound - 1

      while index < end {
        while index < end,
          bytes[index].isHorizontalWhitespace
            || bytes[index].isLineBreak
        {
          metrics.visit()
          index += 1
        }
        if index >= end || bytes[index] == .slash { break }

        let nameStart = index
        while index < end,
          !bytes[index].isAttributeNameTerminator
        {
          metrics.visit()
          index += 1
        }
        let nameEnd = index
        guard nameEnd > nameStart else {
          index += 1
          continue
        }
        while index < end,
          bytes[index].isHorizontalWhitespace
            || bytes[index].isLineBreak
        {
          metrics.visit()
          index += 1
        }
        guard index < end, bytes[index] == .equals else {
          continue
        }
        index += 1
        while index < end,
          bytes[index].isHorizontalWhitespace
            || bytes[index].isLineBreak
        {
          metrics.visit()
          index += 1
        }

        let valueRange: Range<Int>
        if index < end,
          bytes[index] == .singleQuote
            || bytes[index] == .doubleQuote
        {
          let quote = bytes[index]
          index += 1
          let valueStart = index
          while index < end, bytes[index] != quote {
            metrics.visit()
            index += 1
          }
          valueRange = valueStart..<index
          if index < end { index += 1 }
        } else {
          let valueStart = index
          while index < end,
            !bytes[index].isUnquotedValueTerminator
          {
            metrics.visit()
            index += 1
          }
          valueRange = valueStart..<index
        }

        guard
          let key = attributeKey(
            in: nameStart..<nameEnd
          ), result[key] == nil
        else {
          continue
        }
        result[key] = valueRange
      }
      return result
    }

    func attributeKey(in range: Range<Int>) -> AttributeKey? {
      if asciiEquals("src", range: range) { return .source }
      if asciiEquals("type", range: range) { return .mimeType }
      if asciiEquals("title", range: range) { return .title }
      if asciiEquals("aria-label", range: range) {
        return .accessibilityLabel
      }
      return nil
    }

    func name(of tag: HTMLTag) -> ElementName? {
      if asciiEquals("audio", range: tag.nameRange) { return .audio }
      if asciiEquals("source", range: tag.nameRange) { return .source }
      return nil
    }

    func elementName(at index: Int) -> (Bool, ElementName)? {
      if tagNameEquals("audio", at: index, closing: false) {
        return (false, .audio)
      }
      if tagNameEquals("audio", at: index, closing: true) {
        return (true, .audio)
      }
      if tagNameEquals("source", at: index, closing: false) {
        return (false, .source)
      }
      if tagNameEquals("source", at: index, closing: true) {
        return (true, .source)
      }
      return nil
    }

    func tagNameEquals(
      _ name: StaticString,
      at index: Int,
      closing: Bool
    ) -> Bool {
      guard index < bytes.count, bytes[index] == .lessThan else {
        return false
      }
      var cursor = index + 1
      if closing {
        guard cursor < bytes.count, bytes[cursor] == .slash else {
          return false
        }
        cursor += 1
      } else if cursor < bytes.count, bytes[cursor] == .slash {
        return false
      }
      return name.withUTF8Buffer { expected in
        guard cursor + expected.count <= bytes.count else { return false }
        for offset in expected.indices
        where
          bytes[cursor + offset].asciiLowercased != expected[offset]
        {
          return false
        }
        let boundary = cursor + expected.count
        return boundary == bytes.count
          || bytes[boundary].isTagNameBoundary
      }
    }

    func isPlausibleTagStart(at index: Int) -> Bool {
      guard index + 1 < bytes.count else { return false }
      let next = bytes[index + 1]
      if next == .slash {
        return index + 2 < bytes.count
          && bytes[index + 2].isASCIILetter
      }
      return next.isASCIILetter
    }

    func closingTagHasOnlyWhitespace(_ tag: HTMLTag) -> Bool {
      guard tag.isClosing else { return false }
      var index = tag.nameRange.upperBound
      let end = tag.range.upperBound - 1
      while index < end {
        guard
          bytes[index].isHorizontalWhitespace
            || bytes[index].isLineBreak
        else {
          return false
        }
        index += 1
      }
      return true
    }

    func hasOnlyHorizontalWhitespaceUntilLineEnd(from start: Int) -> Bool {
      var index = start
      while index < bytes.count, !bytes[index].isLineBreak {
        guard bytes[index].isHorizontalWhitespace else {
          return false
        }
        index += 1
      }
      return true
    }

    // MARK: Rewriting

    mutating func fallbackBytes(
      for element: ParsedAudioElement,
      htmlOpaque: [Range<Int>]
    ) -> [UInt8] {
      var result: [UInt8] = []
      result.reserveCapacity(element.range.count)
      appendLineBreaks(
        from: element.openingTag.range,
        to: &result
      )

      let contentEnd =
        element.closingTag?.range.lowerBound
        ?? element.range.upperBound
      var cursor = element.openingTag.range.upperBound
      var copyStart = cursor
      var opaqueIndex = 0
      while opaqueIndex < htmlOpaque.count,
        htmlOpaque[opaqueIndex].upperBound <= cursor
      {
        opaqueIndex += 1
      }

      while cursor < contentEnd {
        while opaqueIndex < htmlOpaque.count,
          htmlOpaque[opaqueIndex].upperBound <= cursor
        {
          opaqueIndex += 1
        }
        if opaqueIndex < htmlOpaque.count,
          htmlOpaque[opaqueIndex].contains(cursor)
        {
          cursor = min(
            htmlOpaque[opaqueIndex].upperBound,
            contentEnd
          )
          continue
        }

        metrics.visit()
        guard bytes[cursor] == .lessThan else {
          cursor += 1
          continue
        }

        guard let tag = scanTag(at: cursor) else {
          cursor += 1
          continue
        }
        guard name(of: tag) == .source else {
          cursor = tag.range.upperBound
          continue
        }

        result.append(contentsOf: bytes[copyStart..<cursor])
        appendLineBreaks(from: tag.range, to: &result)
        cursor = min(tag.range.upperBound, contentEnd)
        copyStart = cursor
      }
      result.append(contentsOf: bytes[copyStart..<contentEnd])
      if let closingTag = element.closingTag {
        appendLineBreaks(from: closingTag.range, to: &result)
      }
      return result
    }

    mutating func lineBreaks(in range: Range<Int>) -> [UInt8] {
      var result: [UInt8] = []
      result.reserveCapacity(min(range.count, 64))
      appendLineBreaks(from: range, to: &result)
      return result
    }

    mutating func appendLineBreaks(
      from range: Range<Int>,
      to output: inout [UInt8]
    ) {
      for index in range {
        metrics.visit()
        if bytes[index].isLineBreak { output.append(bytes[index]) }
      }
    }

    mutating func applying(_ edits: [Edit]) -> [UInt8] {
      var output: [UInt8] = []
      output.reserveCapacity(bytes.count)
      var cursor = 0
      for edit in edits {
        guard edit.range.lowerBound >= cursor else { continue }
        output.append(contentsOf: bytes[cursor..<edit.range.lowerBound])
        output.append(contentsOf: edit.replacement)
        cursor = edit.range.upperBound
      }
      output.append(contentsOf: bytes[cursor...])
      metrics.visit(bytes.count)
      return output
    }

    // MARK: Entity decoding

    mutating func decodeHTMLEntities(_ range: Range<Int>) -> String {
      var output: [UInt8] = []
      output.reserveCapacity(range.count)
      var index = range.lowerBound
      while index < range.upperBound {
        metrics.visit()
        guard bytes[index] == .ampersand else {
          output.append(bytes[index])
          index += 1
          continue
        }

        let searchEnd = min(index + 16, range.upperBound)
        var semicolon = index + 1
        while semicolon < searchEnd,
          bytes[semicolon] != .semicolon
        {
          metrics.visit()
          semicolon += 1
        }
        guard semicolon < searchEnd,
          let replacement = decodedEntity(
            in: (index + 1)..<semicolon
          )
        else {
          output.append(bytes[index])
          index += 1
          continue
        }
        output.append(contentsOf: replacement.utf8)
        index = semicolon + 1
      }
      return String(decoding: output, as: UTF8.self)
    }

    func decodedEntity(in range: Range<Int>) -> String? {
      if asciiEquals("quot", range: range) { return "\"" }
      if asciiEquals("apos", range: range) { return "'" }
      if asciiEquals("lt", range: range) { return "<" }
      if asciiEquals("gt", range: range) { return ">" }
      if asciiEquals("nbsp", range: range) { return " " }
      if asciiEquals("amp", range: range) { return "&" }
      guard !range.isEmpty, bytes[range.lowerBound] == .hash else {
        return nil
      }

      var index = range.lowerBound + 1
      var radix = 10
      if index < range.upperBound,
        bytes[index] == .lowerX || bytes[index] == .upperX
      {
        radix = 16
        index += 1
      }
      guard index < range.upperBound else { return nil }
      var value: UInt32 = 0
      while index < range.upperBound {
        let digit: UInt32
        switch bytes[index] {
        case .zero ... .nine:
          digit = UInt32(bytes[index] - .zero)
        case .uppercaseA ... .uppercaseF where radix == 16:
          digit = UInt32(bytes[index] - .uppercaseA + 10)
        case .lowercaseA ... .lowercaseF where radix == 16:
          digit = UInt32(bytes[index] - .lowercaseA + 10)
        default:
          return nil
        }
        guard value <= (UInt32.max - digit) / UInt32(radix) else {
          return nil
        }
        value = value * UInt32(radix) + digit
        index += 1
      }
      guard let scalar = UnicodeScalar(value) else { return nil }
      return String(scalar)
    }

    // MARK: Range and byte helpers

    mutating func lineBounds(
      startingAt start: Int
    ) -> (content: Range<Int>, end: Int) {
      var index = start
      while index < bytes.count, !bytes[index].isLineBreak {
        metrics.visit()
        index += 1
      }
      let contentEnd = index
      if index < bytes.count {
        metrics.visit()
        if bytes[index] == .carriageReturn,
          index + 1 < bytes.count,
          bytes[index + 1] == .lineFeed
        {
          metrics.visit()
          index += 2
        } else {
          index += 1
        }
      }
      return (start..<contentEnd, index)
    }

    func nextLineStart(after index: Int) -> Int {
      var cursor = min(index, bytes.count)
      while cursor < bytes.count {
        if bytes[cursor] == .lineFeed {
          return cursor + 1
        }
        if bytes[cursor] == .carriageReturn {
          if cursor + 1 < bytes.count,
            bytes[cursor + 1] == .lineFeed
          {
            return cursor + 2
          }
          return cursor + 1
        }
        cursor += 1
      }
      return bytes.count
    }

    func isLineStart(_ index: Int) -> Bool {
      guard index > 0 else { return true }
      return bytes[index - 1].isLineBreak
    }

    func asciiEquals(_ value: StaticString, range: Range<Int>) -> Bool {
      value.withUTF8Buffer { expected in
        guard range.count == expected.count else { return false }
        for offset in expected.indices
        where
          bytes[range.lowerBound + offset].asciiLowercased
            != expected[offset]
        {
          return false
        }
        return true
      }
    }

    func hasBytes(_ value: StaticString, at index: Int) -> Bool {
      value.withUTF8Buffer { expected in
        guard index + expected.count <= bytes.count else { return false }
        for offset in expected.indices
        where bytes[index + offset] != expected[offset] {
          return false
        }
        return true
      }
    }

    func merge(
      _ lhs: [Range<Int>],
      _ rhs: [Range<Int>]
    ) -> [Range<Int>] {
      var result: [Range<Int>] = []
      result.reserveCapacity(lhs.count + rhs.count)
      var left = 0
      var right = 0
      while left < lhs.count || right < rhs.count {
        let next: Range<Int>
        if right >= rhs.count
          || (left < lhs.count
            && lhs[left].lowerBound <= rhs[right].lowerBound)
        {
          next = lhs[left]
          left += 1
        } else {
          next = rhs[right]
          right += 1
        }
        appendMerged(next, to: &result)
      }
      return result
    }

    func appendMerged(
      _ range: Range<Int>,
      to ranges: inout [Range<Int>]
    ) {
      guard !range.isEmpty else { return }
      guard let last = ranges.last,
        range.lowerBound <= last.upperBound
      else {
        ranges.append(range)
        return
      }
      ranges[ranges.count - 1] = (last.lowerBound..<max(last.upperBound, range.upperBound))
    }
  }
}

nonisolated extension UInt8 {
  fileprivate static let tab: UInt8 = 0x09
  fileprivate static let lineFeed: UInt8 = 0x0A
  fileprivate static let carriageReturn: UInt8 = 0x0D
  fileprivate static let space: UInt8 = 0x20
  fileprivate static let doubleQuote: UInt8 = 0x22
  fileprivate static let hash: UInt8 = 0x23
  fileprivate static let ampersand: UInt8 = 0x26
  fileprivate static let singleQuote: UInt8 = 0x27
  fileprivate static let hyphen: UInt8 = 0x2D
  fileprivate static let slash: UInt8 = 0x2F
  fileprivate static let zero: UInt8 = 0x30
  fileprivate static let nine: UInt8 = 0x39
  fileprivate static let semicolon: UInt8 = 0x3B
  fileprivate static let lessThan: UInt8 = 0x3C
  fileprivate static let equals: UInt8 = 0x3D
  fileprivate static let greaterThan: UInt8 = 0x3E
  fileprivate static let uppercaseA: UInt8 = 0x41
  fileprivate static let uppercaseF: UInt8 = 0x46
  fileprivate static let upperX: UInt8 = 0x58
  fileprivate static let backslash: UInt8 = 0x5C
  fileprivate static let backtick: UInt8 = 0x60
  fileprivate static let lowercaseA: UInt8 = 0x61
  fileprivate static let lowercaseF: UInt8 = 0x66
  fileprivate static let lowerX: UInt8 = 0x78
  fileprivate static let tilde: UInt8 = 0x7E

  fileprivate var isHorizontalWhitespace: Bool {
    self == .space || self == .tab
  }

  fileprivate var isLineBreak: Bool {
    self == .lineFeed || self == .carriageReturn
  }

  fileprivate var isTagNameByte: Bool {
    switch self {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x3A:
      true
    default:
      false
    }
  }

  fileprivate var isASCIILetter: Bool {
    (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
  }

  fileprivate var isTagNameBoundary: Bool {
    isHorizontalWhitespace || isLineBreak || self == .slash
      || self == .greaterThan
  }

  fileprivate var isAttributeNameTerminator: Bool {
    isHorizontalWhitespace || isLineBreak || self == .equals
      || self == .slash || self == .greaterThan
  }

  fileprivate var isUnquotedValueTerminator: Bool {
    isHorizontalWhitespace || isLineBreak || self == .greaterThan
  }

  fileprivate var asciiLowercased: UInt8 {
    (0x41...0x5A).contains(self) ? self + 0x20 : self
  }
}
