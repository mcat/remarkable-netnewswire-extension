import XCTest
@testable import RemarkableKit

final class HTMLParsingTests: XCTestCase {
    func testTokenizerHandlesTagsAttributesAndComments() {
        let tokens = HTMLTokenizer.tokenize("<p class=\"x\" data-a='1' hidden>Hi &amp; bye<!-- c --><br/></p>")
        XCTAssertEqual(tokens, [
            .startTag(name: "p", attributes: ["class": "x", "data-a": "1", "hidden": ""], selfClosing: false),
            .text("Hi & bye"),
            .startTag(name: "br", attributes: [:], selfClosing: true),
            .endTag(name: "p"),
        ])
    }

    func testTokenizerSkipsScriptAndStyleContent() {
        let tokens = HTMLTokenizer.tokenize("<div><script>var a = '<p>no</p>';</script><style>p{}</style>yes</div>")
        XCTAssertEqual(tokens, [
            .startTag(name: "div", attributes: [:], selfClosing: false),
            .startTag(name: "script", attributes: [:], selfClosing: false),
            .endTag(name: "script"),
            .startTag(name: "style", attributes: [:], selfClosing: false),
            .endTag(name: "style"),
            .text("yes"),
            .endTag(name: "div"),
        ])
    }

    func testEntityDecoding() {
        XCTAssertEqual(HTMLEntities.decode("a &lt; b &gt; c &quot;d&quot; &#169; &#x1F600; &eacute; &nbsp;x"), "a < b > c \"d\" © 😀 é \u{00A0}x")
        XCTAssertEqual(HTMLEntities.decode("&unknown; &"), "&unknown; &")
        XCTAssertEqual(HTMLEntities.decode("&copy 2020"), "© 2020")
    }

    func testParagraphsHeadingsAndInlineStyles() {
        let html = """
        <h1>Title</h1>
        <p>Hello <b>bold</b> and <em>italic</em>, plus <code>code</code>.</p>
        <p>   Second
           paragraph   </p>
        """
        let blocks = HTMLDocumentBuilder.blocks(fromHTML: html)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .heading(level: 1, [InlineRun("Title")]))
        XCTAssertEqual(blocks[1], .paragraph([
            InlineRun("Hello "),
            InlineRun("bold", style: [.bold]),
            InlineRun(" and "),
            InlineRun("italic", style: [.italic]),
            InlineRun(", plus "),
            InlineRun("code", style: [.code]),
            InlineRun("."),
        ]))
        XCTAssertEqual(blocks[2], .paragraph([InlineRun("Second paragraph")]))
    }

    func testListsAndQuotes() {
        let html = "<ul><li>One</li><li>Two<ul><li>Nested</li></ul>tail</li></ul><ol><li>First</li></ol><blockquote><p>Quoted</p></blockquote>"
        let blocks = HTMLDocumentBuilder.blocks(fromHTML: html)
        XCTAssertEqual(blocks, [
            .listItem(ordered: false, index: 1, depth: 1, showsMarker: true, [InlineRun("One")]),
            .listItem(ordered: false, index: 2, depth: 1, showsMarker: true, [InlineRun("Two")]),
            .listItem(ordered: false, index: 1, depth: 2, showsMarker: true, [InlineRun("Nested")]),
            .listItem(ordered: false, index: 2, depth: 1, showsMarker: false, [InlineRun("tail")]),
            .listItem(ordered: true, index: 1, depth: 1, showsMarker: true, [InlineRun("First")]),
            .quote(depth: 1, [InlineRun("Quoted")]),
        ])
    }

    func testImagesLinksAndRules() {
        let base = URL(string: "https://example.com/posts/1")!
        let html = """
        <p>See <a href="/about">about</a>.</p>
        <img src="../images/a.png" alt="A" width="1" height="1">
        <img src="../images/b.jpg" alt="B">
        <figure><img data-src="https://cdn.example.com/c.webp"><figcaption>Caption</figcaption></figure>
        <hr>
        <img src="data:image/png;base64,iVBORw0KGgo=">
        """
        let blocks = HTMLDocumentBuilder.blocks(fromHTML: html, options: .init(baseURL: base))
        XCTAssertEqual(blocks[0], .paragraph([
            InlineRun("See "),
            InlineRun("about", style: [.link], linkURL: URL(string: "https://example.com/about")!),
            InlineRun("."),
        ]))
        XCTAssertEqual(blocks[1], .image(ImageRef(url: URL(string: "https://example.com/images/b.jpg")!, alt: "B")))
        XCTAssertEqual(blocks[2], .image(ImageRef(url: URL(string: "https://cdn.example.com/c.webp")!)))
        XCTAssertEqual(blocks[3], .caption([InlineRun("Caption")]))
        XCTAssertEqual(blocks[4], .rule)
        if case .image(let ref) = blocks[5] {
            XCTAssertNil(ref.url)
            XCTAssertEqual(ref.data, Data(base64Encoded: "iVBORw0KGgo="))
        } else {
            XCTFail("expected a data image, got \(blocks[5])")
        }
        XCTAssertEqual(blocks.count, 6)
    }

    func testPreservesCodeBlocksAndLineBreaks() {
        let html = "<pre><code>line 1\n  line 2 &lt;x&gt;</code></pre><p>a<br>b</p>"
        let blocks = HTMLDocumentBuilder.blocks(fromHTML: html)
        XCTAssertEqual(blocks, [
            .code("line 1\n  line 2 <x>"),
            .paragraph([InlineRun("a\u{2028}b")]),
        ])
    }

    func testPageChromeIsSkippedInPageMode() {
        let html = "<nav><p>Menu</p></nav><article><p>Body</p></article><footer><p>Footer</p></footer>"
        let blocks = HTMLDocumentBuilder.blocks(fromHTML: html, options: .init(skipPageChrome: true))
        XCTAssertEqual(blocks, [.paragraph([InlineRun("Body")])])
        let all = HTMLDocumentBuilder.blocks(fromHTML: html)
        XCTAssertEqual(all.count, 3)
    }

    func testEmbeddedMediaBecomesNote() {
        let blocks = HTMLDocumentBuilder.blocks(fromHTML: "<p>Intro</p><iframe src=\"https://www.youtube.com/embed/x\"></iframe><p>After</p>")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .paragraph([InlineRun("[Embedded media: https://www.youtube.com/embed/x]", style: [.italic])]))
    }

    func testMalformedMarkupDoesNotCrash() {
        let samples = ["<p><b>unclosed", "</div></p>text", "<a href=>x</a>", "<img", "<<<>>>", "&#;&#x;", "<p attr=\"unterminated>text"]
        for sample in samples {
            _ = HTMLDocumentBuilder.blocks(fromHTML: sample)
        }
    }
}
