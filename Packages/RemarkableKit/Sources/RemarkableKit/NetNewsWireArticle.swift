import Foundation

/// The article payload NetNewsWire places on the pasteboard when sharing.
///
/// NetNewsWire's `ArticlePasteboardWriter` exports a property list dictionary
/// under the type identifier ``typeIdentifier``. Only the keys this extension
/// needs are decoded.
public struct NetNewsWireArticle: Equatable {
    public static let typeIdentifier = "com.ranchero.article"

    public var title: String?
    public var contentHTML: String?
    public var contentText: String?
    public var summary: String?
    public var url: URL?
    public var externalURL: URL?
    public var imageURL: URL?
    public var feedURL: URL?
    public var datePublished: Date?
    public var authors: [String]

    public init(title: String? = nil, contentHTML: String? = nil, contentText: String? = nil, summary: String? = nil,
                url: URL? = nil, externalURL: URL? = nil, imageURL: URL? = nil, feedURL: URL? = nil,
                datePublished: Date? = nil, authors: [String] = []) {
        self.title = title
        self.contentHTML = contentHTML
        self.contentText = contentText
        self.summary = summary
        self.url = url
        self.externalURL = externalURL
        self.imageURL = imageURL
        self.feedURL = feedURL
        self.datePublished = datePublished
        self.authors = authors
    }

    public init?(dictionary: [String: Any]) {
        let string: (String) -> String? = { key in
            guard let value = dictionary[key] as? String else { return nil }
            return value.isEmpty ? nil : value
        }
        let url: (String) -> URL? = { key in
            string(key).flatMap { URL(string: $0) }
        }
        title = string("title")
        contentHTML = string("contentHTML")
        contentText = string("contentText")
        summary = string("summary")
        self.url = url("url")
        externalURL = url("externalURL")
        imageURL = url("imageURL")
        feedURL = url("feedURL")
        datePublished = dictionary["datePublished"] as? Date ?? dictionary["dateModified"] as? Date
        if let authorDictionaries = dictionary["authors"] as? [[String: Any]] {
            authors = authorDictionaries.compactMap { author in
                guard let name = author["name"] as? String, !name.isEmpty else { return nil }
                return name
            }
        } else {
            authors = []
        }
        if title == nil, contentHTML == nil, contentText == nil, summary == nil, self.url == nil {
            return nil
        }
    }

    public init?(propertyListData data: Data) {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        self.init(dictionary: dictionary)
    }

    /// The link most useful to a reader: the permalink, or the external link.
    public var preferredURL: URL? {
        url ?? externalURL
    }

    /// Builds a renderable document from the article.
    public func makeDocument() -> ArticleDocument {
        let base = preferredURL ?? feedURL
        var blocks: [Block]
        if let html = contentHTML {
            blocks = HTMLDocumentBuilder.blocks(fromHTML: html, options: .init(baseURL: base))
        } else if let text = contentText ?? summary {
            blocks = ArticleDocumentFactory.blocks(fromPlainText: text)
        } else {
            blocks = []
        }

        // Feed-level featured image, when the body does not already contain it.
        if let imageURL, !blocks.contains(where: { block in
            if case .image(let ref) = block { return ref.url == imageURL }
            return false
        }) {
            blocks.insert(.image(ImageRef(url: imageURL)), at: 0)
        }

        let title = (self.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ArticleDocument(
            title: title.isEmpty ? ArticleDocumentFactory.fallbackTitle(for: blocks, url: preferredURL) : title,
            authors: authors,
            sourceName: (preferredURL ?? feedURL).flatMap(ArticleDocumentFactory.displayHost),
            url: preferredURL,
            date: datePublished,
            blocks: blocks
        )
    }
}

/// Helpers shared by the different input paths.
public enum ArticleDocumentFactory {
    /// Splits plain text into paragraphs on blank lines.
    public static func blocks(fromPlainText text: String) -> [Block] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { paragraph in
                let joined = paragraph.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\u{2028}")
                return .paragraph([InlineRun(joined)])
            }
    }

    /// Builds a document from text that has no metadata of its own.
    public static func document(fromPlainText text: String) -> ArticleDocument {
        var blocks = blocks(fromPlainText: text)
        var title = "Shared text"
        if let first = blocks.first, case .paragraph(let runs) = first {
            let candidate = runs.plainText.replacingOccurrences(of: "\u{2028}", with: " ")
            if candidate.count <= 120 {
                title = candidate
                blocks.removeFirst()
            }
        }
        return ArticleDocument(title: title, blocks: blocks)
    }

    public static func fallbackTitle(for blocks: [Block], url: URL?) -> String {
        for block in blocks {
            if case .heading(_, let runs) = block {
                let text = runs.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        if let url {
            let last = url.lastPathComponent.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            if !last.isEmpty, last != "/" { return last }
            if let host = url.host { return host }
        }
        return "Untitled article"
    }

    /// `www.example.com` → `example.com`.
    public static func displayHost(for url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }
}
