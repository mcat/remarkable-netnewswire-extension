import XCTest
@testable import RemarkableKit

final class ArticleTests: XCTestCase {
    func testNetNewsWireDictionaryIsDecoded() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let dictionary: [String: Any] = [
            "title": "A post",
            "contentHTML": "<p>Hello <b>world</b></p><img src=\"/pic.png\">",
            "url": "https://graybeard.ing/posts/a-post",
            "feedURL": "https://graybeard.ing/feed.xml",
            "imageURL": "https://graybeard.ing/hero.jpg",
            "datePublished": date,
            "authors": [["name": "Salem", "url": "https://graybeard.ing"]],
        ]
        let article = try XCTUnwrap(NetNewsWireArticle(dictionary: dictionary))
        XCTAssertEqual(article.title, "A post")
        XCTAssertEqual(article.authors, ["Salem"])
        XCTAssertEqual(article.datePublished, date)

        let document = article.makeDocument()
        XCTAssertEqual(document.title, "A post")
        XCTAssertEqual(document.sourceName, "graybeard.ing")
        XCTAssertEqual(document.url, URL(string: "https://graybeard.ing/posts/a-post"))
        XCTAssertEqual(document.blocks, [
            .image(ImageRef(url: URL(string: "https://graybeard.ing/hero.jpg")!)),
            .paragraph([InlineRun("Hello "), InlineRun("world", style: [.bold])]),
            .image(ImageRef(url: URL(string: "https://graybeard.ing/pic.png")!)),
        ])
        XCTAssertEqual(document.remoteImageURLs.count, 2)
    }

    func testNetNewsWirePropertyListRoundTrip() throws {
        let plist: [String: Any] = ["title": "T", "contentText": "Body text\n\nMore"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let article = try XCTUnwrap(NetNewsWireArticle(propertyListData: data))
        let document = article.makeDocument()
        XCTAssertEqual(document.blocks, [.paragraph([InlineRun("Body text")]), .paragraph([InlineRun("More")])])
    }

    func testEmptyDictionaryIsRejected() {
        XCTAssertNil(NetNewsWireArticle(dictionary: ["read": true]))
    }

    func testWebPageExtractorUsesMetadataAndArticleElement() {
        let html = """
        <html><head><title>Fallback title | Site</title>
        <meta property="og:title" content="Real title">
        <meta name="author" content="Jane Doe">
        <meta property="og:site_name" content="Example Site">
        <meta property="article:published_time" content="2024-05-01T10:00:00Z">
        </head><body><nav><a href="/">Home</a></nav>
        <article><h1>Real title</h1><p>Body</p></article>
        <footer>Footer</footer></body></html>
        """
        let document = WebPageExtractor.document(fromPage: html, url: URL(string: "https://www.example.com/x")!)
        XCTAssertEqual(document.title, "Real title")
        XCTAssertEqual(document.authors, ["Jane Doe"])
        XCTAssertEqual(document.sourceName, "Example Site")
        XCTAssertEqual(document.date, WebPageExtractor.parseDate("2024-05-01T10:00:00Z"))
        XCTAssertEqual(document.blocks, [.paragraph([InlineRun("Body")])])
    }

    func testWebPageExtractorFallsBackToBody() {
        let html = "<html><body><p>Only body</p></body></html>"
        let document = WebPageExtractor.document(fromPage: html, url: URL(string: "https://example.com/some-post")!)
        XCTAssertEqual(document.title, "some post")
        XCTAssertEqual(document.blocks, [.paragraph([InlineRun("Only body")])])
    }

    func testPlainTextDocument() {
        let document = ArticleDocumentFactory.document(fromPlainText: "Headline\n\nFirst para\nsecond line\n\nSecond para")
        XCTAssertEqual(document.title, "Headline")
        XCTAssertEqual(document.blocks, [
            .paragraph([InlineRun("First para\u{2028}second line")]),
            .paragraph([InlineRun("Second para")]),
        ])
    }

    func testFileNaming() {
        let document = ArticleDocument(title: "  Why  e-ink/rocks: a story  ", sourceName: "graybeard.ing")
        XCTAssertEqual(FileNaming.visibleName(for: document), "Why e-ink rocks a story")
        XCTAssertEqual(FileNaming.visibleName(for: document, prefixSourceName: true), "graybeard.ing – Why e-ink rocks a story")
        let long = ArticleDocument(title: String(repeating: "x", count: 300))
        XCTAssertEqual(FileNaming.visibleName(for: long).count, FileNaming.maxLength)
        XCTAssertEqual(FileNaming.visibleName(for: ArticleDocument(title: "///")), "Article")
    }

    func testSettingsRoundTripAndDefaults() throws {
        var settings = SendSettings()
        settings.transport = .usb
        settings.fontScale = 1.2
        settings.pageSize = .paperPro
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SendSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.pageSize, .paperPro)

        let partial = try JSONDecoder().decode(SendSettings.self, from: Data("{\"includeImages\":false}".utf8))
        XCTAssertFalse(partial.includeImages)
        XCTAssertEqual(partial.transport, .cloud)
        XCTAssertEqual(partial.pageSize, .remarkable2)
    }
}
