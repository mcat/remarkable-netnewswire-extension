import Foundation

/// Converts a stream of ``HTMLToken`` into ``Block``s.
///
/// The builder is deliberately tolerant: unmatched end tags are ignored,
/// unclosed elements are closed at the end, and unknown elements are treated
/// as inline containers.
public struct HTMLDocumentBuilder {
    public struct Options {
        /// Base URL used to resolve relative image and link URLs.
        public var baseURL: URL?
        /// Drop navigation, sidebars, footers and forms. Useful for whole web pages.
        public var skipPageChrome: Bool

        public init(baseURL: URL? = nil, skipPageChrome: Bool = false) {
            self.baseURL = baseURL
            self.skipPageChrome = skipPageChrome
        }
    }

    static let blockElements: Set<String> = [
        "p", "div", "section", "article", "main", "header", "footer", "aside", "nav", "figure", "figcaption",
        "table", "thead", "tbody", "tfoot", "tr", "ul", "ol", "li", "dl", "dt", "dd", "blockquote", "pre",
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "address", "details", "summary", "form", "fieldset", "center",
    ]
    static let voidElements: Set<String> = [
        "br", "img", "hr", "input", "meta", "link", "source", "wbr", "area", "base", "col", "embed", "param", "track",
    ]
    static let alwaysSkipped: Set<String> = [
        "script", "style", "noscript", "template", "head", "title", "svg", "math", "button", "select", "textarea",
        "input", "canvas", "map", "object",
    ]
    static let chromeElements: Set<String> = ["nav", "aside", "footer", "form"]

    private struct OpenElement {
        let name: String
        let skipped: Bool
        let href: URL?
    }

    private struct ListContext {
        let ordered: Bool
        var counter: Int
        var markerPending: Bool
    }

    public var options: Options

    private var stack: [OpenElement] = []
    private var lists: [ListContext] = []
    private var runs: [InlineRun] = []
    private var blocks: [Block] = []
    private var codeText = ""
    private var preDepth = 0
    private var dropLeadingSpace = true

    public init(options: Options = Options()) {
        self.options = options
    }

    public static func blocks(fromHTML html: String, options: Options = Options()) -> [Block] {
        blocks(from: HTMLTokenizer.tokenize(html), options: options)
    }

    public static func blocks(from tokens: [HTMLToken], options: Options = Options()) -> [Block] {
        var builder = HTMLDocumentBuilder(options: options)
        for token in tokens {
            builder.consume(token)
        }
        return builder.finish()
    }

    // MARK: - Token handling

    public mutating func consume(_ token: HTMLToken) {
        switch token {
        case .text(let text):
            appendText(text)
        case .startTag(let name, let attributes, let selfClosing):
            startElement(name, attributes: attributes, selfClosing: selfClosing)
        case .endTag(let name):
            endElement(name)
        }
    }

    public mutating func finish() -> [Block] {
        flushParagraph()
        if preDepth > 0 {
            flushCode()
        }
        stack.removeAll()
        lists.removeAll()
        let result = blocks
        blocks.removeAll()
        return result
    }

    private var isSkipping: Bool {
        stack.contains { $0.skipped }
    }

    private mutating func startElement(_ name: String, attributes: [String: String], selfClosing: Bool) {
        let skippedHere = HTMLDocumentBuilder.alwaysSkipped.contains(name)
            || (options.skipPageChrome && HTMLDocumentBuilder.chromeElements.contains(name))

        if isSkipping || skippedHere {
            if !HTMLDocumentBuilder.voidElements.contains(name), !selfClosing {
                stack.append(OpenElement(name: name, skipped: skippedHere || isSkipping, href: nil))
            }
            return
        }

        switch name {
        case "br":
            if preDepth > 0 {
                codeText.append("\n")
            } else {
                let (style, link) = currentStyle()
                appendRun("\u{2028}", style: style, link: link)
                dropLeadingSpace = true
            }
            return
        case "img":
            handleImage(attributes: attributes)
            return
        case "hr":
            flushParagraph()
            blocks.append(.rule)
            return
        case "iframe", "video", "audio", "embed":
            if let src = attributes["src"] ?? attributes["data-src"], let url = resolve(src) {
                flushParagraph()
                runs.append(InlineRun("[Embedded media: \(url.absoluteString)]", style: [.italic]))
                flushParagraph()
            }
            if !HTMLDocumentBuilder.voidElements.contains(name), !selfClosing {
                stack.append(OpenElement(name: name, skipped: true, href: nil))
            }
            return
        default:
            break
        }

        if HTMLDocumentBuilder.voidElements.contains(name) {
            return
        }

        if HTMLDocumentBuilder.blockElements.contains(name) {
            flushParagraph()
        }

        switch name {
        case "p":
            if stack.last?.name == "p" {
                stack.removeLast()
            }
        case "ul", "ol":
            lists.append(ListContext(ordered: name == "ol", counter: 0, markerPending: false))
        case "li":
            closeOpenListItem()
            if lists.isEmpty {
                lists.append(ListContext(ordered: false, counter: 0, markerPending: false))
            }
            lists[lists.count - 1].counter += 1
            lists[lists.count - 1].markerPending = true
        case "pre":
            if preDepth == 0 {
                codeText = ""
            }
            preDepth += 1
        case "td", "th":
            if !runs.isEmpty, runs.last?.text.hasSuffix("\u{2028}") == false {
                runs.append(InlineRun("  |  "))
                dropLeadingSpace = true
            }
        default:
            break
        }

        var href: URL?
        if name == "a", let raw = attributes["href"] {
            href = resolve(raw)
        }
        if !selfClosing {
            stack.append(OpenElement(name: name, skipped: false, href: href))
        }
    }

    private mutating func endElement(_ name: String) {
        guard let position = stack.lastIndex(where: { $0.name == name }) else {
            return
        }
        // Close every element above the matched one as well.
        let closing = stack[position...]
        for element in closing.reversed() where !element.skipped {
            closeElementEffects(element.name)
        }
        stack.removeSubrange(position...)
    }

    /// Side effects of closing an element that are not just popping the stack.
    private mutating func closeElementEffects(_ name: String) {
        if HTMLDocumentBuilder.blockElements.contains(name) {
            if name == "pre" {
                preDepth = max(0, preDepth - 1)
                if preDepth == 0 {
                    flushCode()
                }
            } else {
                flushParagraph()
            }
        }
        switch name {
        case "ul", "ol":
            if !lists.isEmpty { lists.removeLast() }
        case "li":
            if !lists.isEmpty { lists[lists.count - 1].markerPending = false }
        default:
            break
        }
    }

    /// Implicitly closes an open `li` when a new one starts in the same list.
    private mutating func closeOpenListItem() {
        var i = stack.count - 1
        while i >= 0 {
            let name = stack[i].name
            if name == "ul" || name == "ol" {
                return
            }
            if name == "li" {
                let closing = stack[i...]
                for element in closing.reversed() where !element.skipped {
                    closeElementEffects(element.name)
                }
                stack.removeSubrange(i...)
                return
            }
            i -= 1
        }
    }

    // MARK: - Text

    private func currentStyle() -> (style: InlineStyle, link: URL?) {
        var style: InlineStyle = []
        var link: URL?
        for element in stack {
            switch element.name {
            case "b", "strong", "th", "dt":
                style.insert(.bold)
            case "i", "em", "cite", "dfn", "var", "q":
                style.insert(.italic)
            case "code", "kbd", "samp", "tt":
                style.insert(.code)
            case "a":
                if let href = element.href {
                    style.insert(.link)
                    link = href
                }
            default:
                break
            }
        }
        return (style, link)
    }

    private mutating func appendText(_ text: String) {
        guard !isSkipping, !text.isEmpty else { return }
        if preDepth > 0 {
            codeText.append(text)
            return
        }
        let collapsed = HTMLDocumentBuilder.collapseWhitespace(text)
        guard !collapsed.isEmpty else { return }
        var piece = Substring(collapsed)
        if dropLeadingSpace, piece.first == " " {
            piece = piece.dropFirst()
        }
        guard !piece.isEmpty else { return }
        dropLeadingSpace = piece.last == " "

        let (style, link) = currentStyle()
        appendRun(String(piece), style: style, link: link)
    }

    /// Appends text, merging it into the previous run when the style matches.
    private mutating func appendRun(_ text: String, style: InlineStyle, link: URL?) {
        if let last = runs.last, last.style == style, last.linkURL == link {
            runs[runs.count - 1].text += text
        } else {
            runs.append(InlineRun(text, style: style, linkURL: link))
        }
    }

    static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var lastWasSpace = false
        for scalar in text.unicodeScalars {
            let isSpace: Bool
            switch scalar {
            case " ", "\t", "\n", "\r", "\u{0C}":
                isSpace = true
            default:
                isSpace = false
            }
            if isSpace {
                if !lastWasSpace {
                    result.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return result
    }

    // MARK: - Blocks

    private mutating func flushParagraph() {
        defer {
            runs.removeAll()
            dropLeadingSpace = true
        }
        // Trim trailing whitespace and line breaks.
        while let last = runs.last {
            let trimmed = String(last.text.reversed().drop(while: { $0 == " " || $0 == "\u{2028}" || $0 == "\u{00A0}" }).reversed())
            if trimmed.isEmpty {
                runs.removeLast()
            } else {
                runs[runs.count - 1].text = trimmed
                break
            }
        }
        if let first = runs.first {
            let trimmed = String(first.text.drop(while: { $0 == " " || $0 == "\u{2028}" || $0 == "\u{00A0}" }))
            if trimmed.isEmpty {
                runs.removeFirst()
            } else {
                runs[0].text = trimmed
            }
        }
        guard !runs.isEmpty else { return }

        let block = makeBlock(runs)
        blocks.append(block)
    }

    private mutating func makeBlock(_ runs: [InlineRun]) -> Block {
        var headingLevel: Int?
        var inListItem = false
        var quoteDepth = 0
        var inCaption = false
        for element in stack {
            switch element.name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                headingLevel = Int(String(element.name.dropFirst())) ?? 6
            case "li":
                inListItem = true
            case "blockquote":
                quoteDepth += 1
            case "figcaption":
                inCaption = true
            default:
                break
            }
        }

        if let level = headingLevel {
            return .heading(level: level, runs)
        }
        if inListItem, let list = lists.last {
            let showsMarker = list.markerPending
            lists[lists.count - 1].markerPending = false
            return .listItem(ordered: list.ordered, index: list.counter, depth: lists.count, showsMarker: showsMarker, runs)
        }
        if quoteDepth > 0 {
            return .quote(depth: quoteDepth, runs)
        }
        if inCaption {
            return .caption(runs)
        }
        return .paragraph(runs)
    }

    private mutating func flushCode() {
        let text = codeText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet.newlines)
        codeText = ""
        guard !text.isEmpty else { return }
        blocks.append(.code(text))
    }

    // MARK: - Images

    private mutating func handleImage(attributes: [String: String]) {
        // Tracking pixels and spacer images.
        if let width = attributes["width"].flatMap(HTMLDocumentBuilder.pixelValue), width <= 2 { return }
        if let height = attributes["height"].flatMap(HTMLDocumentBuilder.pixelValue), height <= 2 { return }

        let candidates = [attributes["src"], attributes["data-src"], attributes["data-original"], attributes["data-lazy-src"]]
        var source = candidates.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if source == nil, let srcset = attributes["srcset"] ?? attributes["data-srcset"] {
            source = HTMLDocumentBuilder.firstCandidate(inSrcset: srcset)
        }
        guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else { return }

        let alt = attributes["alt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var ref = ImageRef(alt: (alt?.isEmpty ?? true) ? nil : alt)
        if source.lowercased().hasPrefix("data:") {
            guard let data = HTMLDocumentBuilder.decodeDataURL(source) else { return }
            ref.data = data
        } else {
            guard let url = resolve(source), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            ref.url = url
        }
        flushParagraph()
        blocks.append(.image(ref))
    }

    static func pixelValue(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = trimmed.hasSuffix("px") ? String(trimmed.dropLast(2)) : trimmed
        return Double(digits)
    }

    static func firstCandidate(inSrcset srcset: String) -> String? {
        for candidate in srcset.split(separator: ",") {
            let parts = candidate.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            if let url = parts.first, !url.isEmpty {
                return String(url)
            }
        }
        return nil
    }

    static func decodeDataURL(_ source: String) -> Data? {
        guard let comma = source.firstIndex(of: ",") else { return nil }
        let header = source[source.startIndex..<comma].lowercased()
        let payload = String(source[source.index(after: comma)...])
        guard header.hasPrefix("data:image/") else { return nil }
        if header.hasSuffix(";base64") {
            let cleaned = payload.filter { !$0.isWhitespace }
            return Data(base64Encoded: cleaned, options: [.ignoreUnknownCharacters])
        }
        return payload.removingPercentEncoding.flatMap { $0.data(using: .utf8) }
    }

    private func resolve(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let base = options.baseURL, let url = URL(string: trimmed, relativeTo: base) {
            return url.absoluteURL
        }
        if let url = URL(string: trimmed) {
            return url
        }
        // Spaces and other unescaped characters are common in the wild.
        let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        if let base = options.baseURL {
            return URL(string: escaped, relativeTo: base)?.absoluteURL
        }
        return URL(string: escaped)
    }
}
