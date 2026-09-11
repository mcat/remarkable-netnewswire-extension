import Foundation

/// Turns a whole HTML page into an ``ArticleDocument``.
///
/// Used when the shared item is only a URL or raw page HTML. It prefers the
/// first `<article>` element, then `<main>`, then `<body>`, and reads the
/// title and author from the page's metadata.
public enum WebPageExtractor {
    public struct PageMetadata: Equatable {
        public var title: String?
        public var author: String?
        public var siteName: String?
        public var published: Date?
    }

    public static func document(fromPage html: String, url: URL?, titleHint: String? = nil) -> ArticleDocument {
        let tokens = HTMLTokenizer.tokenize(html)
        let metadata = metadata(from: tokens)
        let contentTokens = contentRegion(in: tokens)
        var blocks = HTMLDocumentBuilder.blocks(from: contentTokens, options: .init(baseURL: url, skipPageChrome: true))

        var title = firstNonEmpty([metadata.title, titleHint])
        if title == nil {
            title = ArticleDocumentFactory.fallbackTitle(for: blocks, url: url)
        }
        let resolvedTitle = title ?? "Untitled article"

        // Drop a leading heading that repeats the title.
        if let first = blocks.first, case .heading(_, let runs) = first,
           normalize(runs.plainText) == normalize(resolvedTitle) {
            blocks.removeFirst()
        }

        return ArticleDocument(
            title: resolvedTitle,
            authors: metadata.author.map { [$0] } ?? [],
            sourceName: metadata.siteName ?? url.flatMap(ArticleDocumentFactory.displayHost),
            url: url,
            date: metadata.published,
            blocks: blocks
        )
    }

    static func metadata(from tokens: [HTMLToken]) -> PageMetadata {
        var metadata = PageMetadata()
        var titleText = ""
        var inTitle = false
        var ogTitle: String?

        for token in tokens {
            switch token {
            case .startTag(let name, let attributes, _):
                if name == "title" {
                    inTitle = true
                } else if name == "meta" {
                    let key = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
                    guard let content = attributes["content"]?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else { continue }
                    switch key {
                    case "og:title", "twitter:title":
                        if ogTitle == nil { ogTitle = content }
                    case "author", "article:author", "parsely-author", "dc.creator":
                        if metadata.author == nil, !content.lowercased().hasPrefix("http") { metadata.author = content }
                    case "og:site_name":
                        if metadata.siteName == nil { metadata.siteName = content }
                    case "article:published_time", "datepublished", "date", "dc.date", "parsely-pub-date":
                        if metadata.published == nil { metadata.published = parseDate(content) }
                    default:
                        break
                    }
                }
            case .endTag(let name):
                if name == "title" { inTitle = false }
            case .text(let text):
                if inTitle { titleText += text }
            }
        }

        let documentTitle = HTMLDocumentBuilder.collapseWhitespace(titleText).trimmingCharacters(in: .whitespaces)
        metadata.title = firstNonEmpty([ogTitle, documentTitle.isEmpty ? nil : documentTitle])
        return metadata
    }

    /// The tokens of the most article-like region of the page.
    static func contentRegion(in tokens: [HTMLToken]) -> [HTMLToken] {
        for candidate in ["article", "main", "body"] {
            if let slice = element(named: candidate, in: tokens) {
                return slice
            }
        }
        return tokens
    }

    /// The tokens strictly inside the first element with the given name.
    static func element(named target: String, in tokens: [HTMLToken]) -> [HTMLToken]? {
        guard let start = tokens.firstIndex(where: {
            if case .startTag(let name, _, let selfClosing) = $0 { return name == target && !selfClosing }
            return false
        }) else {
            return nil
        }
        var depth = 0
        var index = start + 1
        while index < tokens.count {
            switch tokens[index] {
            case .startTag(let name, _, let selfClosing) where name == target && !selfClosing:
                depth += 1
            case .endTag(let name) where name == target:
                if depth == 0 {
                    return Array(tokens[(start + 1)..<index])
                }
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return Array(tokens[(start + 1)...])
    }

    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: String(text.prefix(10))) { return date }
        return nil
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        HTMLDocumentBuilder.collapseWhitespace(text).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
