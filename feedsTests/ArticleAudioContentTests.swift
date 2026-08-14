import Foundation
import Testing

@testable import feeds

@Suite(.serialized)
struct ArticleAudioContentTests {
  @Test func extractsDirectAudioWithoutSplittingTheMarkdownDocument() throws {
    let element =
      #"<audio controls src="https://cdn.example.com/story.mp3" title="Listen &amp; learn"></audio>"#
    let markdown = """
      # Introduction

      Before the player.

      \(element)

      After the player.
      """

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )

    let audio = try #require(document.audio.first)
    #expect(document.audio.count == 1)
    #expect(
      document.markdown
        == markdown.replacingOccurrences(of: element, with: "")
    )
    #expect(audio.label == "Listen & learn")
    #expect(
      audio.sources.map(\.url.absoluteString) == [
        "https://cdn.example.com/story.mp3"
      ]
    )
  }

  @Test func recognizesQuotedGreaterThanCommentsSourcesAndClosingTag() throws {
    let markdown = """
      <AuDiO title="1 > 0 &amp; ready">
        <!-- A fake close must not win: </audio> -->
        <div data-example="<source src='https://fake.example/attribute.mp3'>"
             data-close="</audio>">Fallback text.</div>
        <source data-note='x > y' src='/audio/episode.ogg' type='Audio/OGG'>
        <source src="/audio/episode.mp3" type="audio/mpeg">
      </AuDiO   >
      """
    let baseURL = try #require(URL(string: "https://example.com/post"))

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: baseURL
    )
    let audio = try #require(document.audio.first)

    #expect(audio.label == "1 > 0 & ready")
    #expect(
      audio.sources.map(\.url.absoluteString) == [
        "https://example.com/audio/episode.ogg",
        "https://example.com/audio/episode.mp3",
      ]
    )
    #expect(audio.sources.map(\.mimeType) == ["audio/ogg", "audio/mpeg"])
    #expect(!document.markdown.contains("<AuDiO"))
    #expect(document.markdown.filter(\.isNewline).count == 4)
  }

  @Test func resolvesAndDeduplicatesNormalizedSourcesInDocumentOrder() throws {
    let markdown = """
      <audio aria-label='Episode audio' src="../media/main.mp3#start">
        <source src="https://example.com:443/posts/media/main.mp3#duplicate" type="audio/mpeg">
        <source src='//cdn.example.com/fallback.m4a' type='Audio/MP4'>
        <source src="https://user:secret@example.com/private.mp3">
        <source src="file:///tmp/private.mp3">
      </audio>
      """
    let baseURL = try #require(
      URL(string: "https://EXAMPLE.com/posts/2026/story")
    )

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: baseURL
    )
    let audio = try #require(document.audio.first)

    #expect(audio.label == "Episode audio")
    #expect(
      audio.sources.map(\.url.absoluteString) == [
        "https://example.com/posts/media/main.mp3",
        "https://cdn.example.com/fallback.m4a",
      ]
    )
    #expect(audio.sources.map(\.mimeType) == [nil, "audio/mp4"])
  }

  @Test func ignoresAudioInEveryProtectedCodeContext() throws {
    let markdown = """
      ```html
      <audio src="https://fake.example/fenced.mp3"></audio>
      ```

      ~~~~
      <audio src="https://fake.example/tilde.mp3"></audio>
      ~~~~

          <audio src="https://fake.example/indented.mp3"></audio>
      \t<audio src="https://fake.example/tabbed.mp3"></audio>

      Before `<audio src="https://fake.example/inline.mp3"></audio>` after.

      `A multiline code span
      <audio src="https://fake.example/span.mp3"></audio>
      ends here`

      <code data-note="1 > 0">
      <audio src="https://fake.example/code.mp3"></audio>
      </code>

      <pre>
      <audio src="https://fake.example/pre.mp3"></audio>
      </pre>

      <!--
      <audio src="https://fake.example/comment.mp3"></audio>
      -->

      <audio src="https://cdn.example.com/real.mp3"></audio>
      """

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )
    let audio = try #require(document.audio.first)

    #expect(document.audio.count == 1)
    #expect(audio.sources.first?.url.absoluteString == "https://cdn.example.com/real.mp3")
    #expect(document.markdown.contains("fake.example/fenced.mp3"))
    #expect(document.markdown.contains("fake.example/inline.mp3"))
    #expect(document.markdown.contains("fake.example/span.mp3"))
    #expect(document.markdown.contains("fake.example/code.mp3"))
    #expect(document.markdown.contains("fake.example/comment.mp3"))
    #expect(!document.markdown.contains("cdn.example.com/real.mp3"))
  }

  @Test func unmatchedOrEscapedBackticksDoNotHideLaterAudio() {
    let markdown = #"""
      An unmatched opener: ``
      An escaped delimiter: \`literal
      <audio src="https://cdn.example.com/after-unmatched.mp3"></audio>
      """#

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )

    #expect(document.audio.count == 1)
    #expect(document.markdown.contains("An unmatched opener: ``"))
    #expect(!document.markdown.contains("after-unmatched.mp3"))
  }

  @Test func extractsOnlyColumnZeroStandaloneAudio() {
    let markdown = #"""
      Inline <audio src="https://fake.example/paragraph.mp3"></audio> text.
       <audio src="https://fake.example/space.mp3"></audio>
      > <audio src="https://fake.example/quote.mp3"></audio>
      - <audio src="https://fake.example/list.mp3"></audio>
      <audiobook src="https://fake.example/name.mp3"></audiobook>
      <source src="https://fake.example/orphan.mp3">
      <audio src="https://cdn.example.com/standalone.mp3"></audio>
      """#

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )

    #expect(document.audio.count == 1)
    #expect(document.markdown.contains("fake.example/paragraph.mp3"))
    #expect(document.markdown.contains("fake.example/space.mp3"))
    #expect(document.markdown.contains("<audiobook"))
    #expect(document.markdown.contains("<source"))
    #expect(!document.markdown.contains("standalone.mp3"))
  }

  @Test func rejectsUnsafeSourcesButPreservesFallbackContent() {
    let markdown = """
      Before.
      <audio autoplay src="javascript:alert(1)">
        <source src="data:audio/mpeg;base64,AAAA">
        <source src="file:///tmp/private.mp3">
        <div data-example="<source src='https://fake.example/attribute.mp3'>">
          This attribute is not an audio source.
        </div>
        <p>Use the written transcript instead.</p>
      </audio>
      After.
      """

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: URL(string: "https://example.com/post")
    )

    #expect(document.audio.isEmpty)
    #expect(document.markdown.contains("Before."))
    #expect(document.markdown.contains("Use the written transcript instead."))
    #expect(document.markdown.contains("After."))
    #expect(!document.markdown.contains("<audio"))
    #expect(!document.markdown.contains(#"<source src="data:audio"#))
    #expect(!document.markdown.contains(#"<source src="file:"#))
    #expect(document.markdown.contains("This attribute is not an audio source."))
    #expect(document.markdown.contains("fake.example/attribute.mp3"))
    #expect(!document.markdown.contains("javascript:"))
    #expect(!document.markdown.contains("data:audio"))
  }

  @Test func malformedOuterAudioDoesNotConsumeANewerStandaloneElement() throws {
    let markdown = #"""
      <audio src="https://fake.example/unclosed.mp3">
      Keep this malformed element and its fallback.
      <audio src="https://cdn.example.com/recovered.mp3"></audio>
      """#

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )
    let audio = try #require(document.audio.first)

    #expect(document.audio.count == 1)
    #expect(audio.sources.first?.url.absoluteString == "https://cdn.example.com/recovered.mp3")
    #expect(document.markdown.contains("fake.example/unclosed.mp3"))
    #expect(document.markdown.contains("Keep this malformed element"))
    #expect(!document.markdown.contains("recovered.mp3"))
  }

  @Test func unterminatedGenericHTMLProtectsTheAmbiguousRemainder() {
    let markdown = #"""
    <div title="unterminated
    <code>
    <audio src="https://cdn.example.com/should-stay.mp3"></audio>
    </code>
    """#

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )

    #expect(document.audio.isEmpty)
    #expect(document.markdown == markdown)
  }

  @Test func keepsReferenceDefinitionsInTheWholeMarkdownDocument() throws {
    let element = #"<audio src="https://cdn.example.com/episode.mp3"></audio>"#
    let markdown = """
      Read [the introduction][episode].

      \(element)

      Then read [the conclusion][episode].

      [episode]: ../episode-notes "Episode notes"
      """
    let baseURL = try #require(
      URL(string: "https://example.com/articles/current")
    )

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: baseURL
    )
    let attributed = try AttributedString(
      markdown: document.markdown,
      baseURL: baseURL
    )
    let links = attributed.runs.compactMap(\.link)

    #expect(
      document.markdown
        == markdown.replacingOccurrences(of: element, with: "")
    )
    #expect(document.markdown.contains("[episode]: ../episode-notes"))
    #expect(links.count == 2)
    #expect(
      links.allSatisfy {
        $0.absoluteString == "https://example.com/episode-notes"
      }
    )
  }

  @Test func enforcesAudioAndSourceCountLimits() {
    let elements = (0..<33).map { index in
      "<audio src=\"https://cdn.example.com/\(index).mp3\"></audio>"
    }
    let manyAudio = elements.joined(separator: "\n")
    let audioDocument = ArticleAudioContentParser.parseSynchronously(
      from: manyAudio,
      baseURL: nil
    )

    #expect(audioDocument.audio.count == 32)
    #expect(audioDocument.markdown.contains(elements[32]))
    #expect(!audioDocument.markdown.contains(elements[31]))

    let sourceTags = (0..<10).map { index in
      "  <source src=\"https://cdn.example.com/source-\(index).mp3\">"
    }.joined(separator: "\n")
    let manySources = "<audio>\n\(sourceTags)\n</audio>"
    let sourceDocument = ArticleAudioContentParser.parseSynchronously(
      from: manySources,
      baseURL: nil
    )

    #expect(sourceDocument.audio.first?.sources.count == 8)
    #expect(
      sourceDocument.audio.first?.sources.last?.url.absoluteString
        == "https://cdn.example.com/source-7.mp3"
    )
  }

  @Test func enforcesInputURLAndLabelLimits() throws {
    let oversizedInput =
      String(
        repeating: "a",
        count: ArticleAudioContentParser.maximumInputByteCount + 1
      ) + #"<audio src="https://cdn.example.com/hidden.mp3"></audio>"#
    let oversizedDocument = ArticleAudioContentParser.parseSynchronously(
      from: oversizedInput,
      baseURL: nil
    )
    #expect(oversizedDocument.markdown == oversizedInput)
    #expect(oversizedDocument.audio.isEmpty)

    let longURL =
      "https://example.com/"
      + String(
        repeating: "a",
        count: ArticleAudioContentParser.maximumURLByteCount
      )
    let invalidURLMarkdown = """
      <audio title="Fallback">
      <source src="\(longURL)">
      Keep the transcript.
      </audio>
      """
    let invalidURLDocument = ArticleAudioContentParser.parseSynchronously(
      from: invalidURLMarkdown,
      baseURL: nil
    )
    #expect(invalidURLDocument.audio.isEmpty)
    #expect(invalidURLDocument.markdown.contains("Keep the transcript."))
    #expect(!invalidURLDocument.markdown.contains(longURL))

    let longLabel = String(repeating: "🎧", count: 300)
    let labelMarkdown =
      "<audio title=\"\(longLabel)\" src=\"https://cdn.example.com/labeled.mp3\"></audio>"
    let labelDocument = ArticleAudioContentParser.parseSynchronously(
      from: labelMarkdown,
      baseURL: nil
    )
    let label = try #require(labelDocument.audio.first?.label)
    #expect(label.count == ArticleAudioContentParser.maximumLabelCharacterCount)
  }

  @Test func preservesCRLFWhenRemovingMultilineAudio() {
    let markdown =
      "Before\r\n<audio>\r\n<source src=\"https://cdn.example.com/crlf.mp3\">\r\n</audio>\r\nAfter"

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )

    #expect(document.audio.count == 1)
    #expect(document.markdown == "Before\r\n\r\n\r\n\r\nAfter")
  }

  @Test func scannerWorkRemainsLinearForPathologicalInput() {
    let malformedRawTag = "<code title=\"unterminated\n"
    let markdown =
      String(repeating: malformedRawTag, count: 20_000)
      + #"<audio src="https://cdn.example.com/must-stay-protected.mp3"></audio>"#

    let result =
      ArticleAudioContentParser
      .parseSynchronouslyWithDiagnostics(
        from: markdown,
        baseURL: nil
      )
    let inputByteCount = markdown.utf8.count

    #expect(result.document.audio.isEmpty)
    #expect(result.document.markdown == markdown)
    #expect(result.visitedByteCount <= inputByteCount * 32 + 1_024)
  }

  @Test func unclosedAudioTokensRemainLinearAndUnchanged() {
    let markdown = String(
      repeating: "<audio ",
      count: ArticleAudioContentParser.maximumInputByteCount / 7
    )

    let result = ArticleAudioContentParser
      .parseSynchronouslyWithDiagnostics(
        from: markdown,
        baseURL: nil
      )
    let inputByteCount = markdown.utf8.count

    #expect(result.document.audio.isEmpty)
    #expect(result.document.markdown == markdown)
    #expect(result.visitedByteCount <= inputByteCount * 32 + 1_024)
  }

  @Test func asynchronousEntryReturnsTheSameDocument() async {
    let markdown = #"<audio src="https://cdn.example.com/async.mp3" />"#

    let synchronous = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )
    let asynchronous = await ArticleAudioContentParser.parse(
      from: markdown,
      baseURL: nil
    )

    #expect(asynchronous == synchronous)
  }

  @Test func leavesPlainMarkdownByteForByteUnchanged() {
    let markdown = "# Plain article\n\nNo media here.\n"

    let document = ArticleAudioContentParser.parseSynchronously(
      from: markdown,
      baseURL: nil
    )

    #expect(document == ArticleAudioDocument(markdown: markdown, audio: []))
  }
}
