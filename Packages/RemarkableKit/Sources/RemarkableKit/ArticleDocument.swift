import Foundation

/// Inline text styling flags carried by an ``InlineRun``.
public struct InlineStyle: OptionSet, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let code = InlineStyle(rawValue: 1 << 2)
    public static let link = InlineStyle(rawValue: 1 << 3)
}

/// A run of text with uniform styling.
public struct InlineRun: Equatable {
    public var text: String
    public var style: InlineStyle
    public var linkURL: URL?

    public init(_ text: String, style: InlineStyle = [], linkURL: URL? = nil) {
        self.text = text
        self.style = style
        self.linkURL = linkURL
    }
}

public extension Array where Element == InlineRun {
    /// The plain text of the runs, joined.
    var plainText: String {
        map(\.text).joined()
    }
}

/// A reference to an image that appears in an article.
public struct ImageRef: Equatable {
    /// Remote location of the image, if it must be fetched.
    public var url: URL?
    /// Inline bytes, when the image was embedded as a data: URL.
    public var data: Data?
    public var alt: String?

    public init(url: URL? = nil, data: Data? = nil, alt: String? = nil) {
        self.url = url
        self.data = data
        self.alt = alt
    }
}

/// A block-level element of an article, in reading order.
public enum Block: Equatable {
    case paragraph([InlineRun])
    case heading(level: Int, [InlineRun])
    case listItem(ordered: Bool, index: Int, depth: Int, showsMarker: Bool, [InlineRun])
    case quote(depth: Int, [InlineRun])
    case caption([InlineRun])
    case code(String)
    case image(ImageRef)
    case rule

    /// The runs of the block, for text-bearing blocks.
    public var runs: [InlineRun]? {
        switch self {
        case .paragraph(let runs), .heading(_, let runs), .listItem(_, _, _, _, let runs),
             .quote(_, let runs), .caption(let runs):
            return runs
        case .code, .image, .rule:
            return nil
        }
    }
}

/// A fully parsed article, ready to be rendered.
public struct ArticleDocument: Equatable {
    public var title: String
    public var authors: [String]
    /// The feed name or site host the article came from.
    public var sourceName: String?
    public var url: URL?
    public var date: Date?
    public var blocks: [Block]

    public init(title: String, authors: [String] = [], sourceName: String? = nil, url: URL? = nil, date: Date? = nil, blocks: [Block] = []) {
        self.title = title
        self.authors = authors
        self.sourceName = sourceName
        self.url = url
        self.date = date
        self.blocks = blocks
    }

    /// Every image referenced by the document, in order.
    public var imageRefs: [ImageRef] {
        blocks.compactMap {
            if case .image(let ref) = $0 { return ref }
            return nil
        }
    }

    /// Remote image URLs that need fetching, without duplicates.
    public var remoteImageURLs: [URL] {
        var seen = Set<URL>()
        var result: [URL] = []
        for ref in imageRefs {
            guard ref.data == nil, let url = ref.url, !seen.contains(url) else { continue }
            seen.insert(url)
            result.append(url)
        }
        return result
    }

    /// A one-line description of where the article came from, for bylines.
    public var byline: String {
        var parts: [String] = []
        if !authors.isEmpty {
            parts.append(authors.joined(separator: ", "))
        }
        if let sourceName, !sourceName.isEmpty {
            parts.append(sourceName)
        }
        if let date {
            parts.append(ArticleDocument.dateFormatter.string(from: date))
        }
        return parts.joined(separator: "  ·  ")
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}

/// Physical page geometry used when rendering a PDF.
public struct PageSizePreset: Equatable, Hashable, Codable, Identifiable, CaseIterable {
    public var id: String
    public var displayName: String
    /// Page size in PDF points (1/72 inch).
    public var widthPoints: Double
    public var heightPoints: Double
    /// Native pixel width of the target screen. Images are downscaled to this width.
    public var pixelWidth: Int

    public static let remarkable2 = PageSizePreset(id: "remarkable2", displayName: "reMarkable 1 / 2 / Paper Pure", pixels: (1404, 1872), dpi: 226)
    public static let paperPro = PageSizePreset(id: "paperPro", displayName: "reMarkable Paper Pro", pixels: (1620, 2160), dpi: 229)
    public static let paperProMove = PageSizePreset(id: "paperProMove", displayName: "reMarkable Paper Pro Move", pixels: (954, 1696), dpi: 264)
    public static let a4 = PageSizePreset(id: "a4", displayName: "A4", widthPoints: 595.28, heightPoints: 841.89, pixelWidth: 1654)

    public static var allCases: [PageSizePreset] { [.remarkable2, .paperPro, .paperProMove, .a4] }

    public init(id: String, displayName: String, widthPoints: Double, heightPoints: Double, pixelWidth: Int) {
        self.id = id
        self.displayName = displayName
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.pixelWidth = pixelWidth
    }

    init(id: String, displayName: String, pixels: (Int, Int), dpi: Double) {
        self.init(
            id: id,
            displayName: displayName,
            widthPoints: Double(pixels.0) * 72.0 / dpi,
            heightPoints: Double(pixels.1) * 72.0 / dpi,
            pixelWidth: pixels.0
        )
    }

    public static func preset(withID id: String) -> PageSizePreset {
        allCases.first { $0.id == id } ?? .remarkable2
    }
}
