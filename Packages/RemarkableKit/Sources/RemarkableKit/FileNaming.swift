import Foundation

/// Produces the document name shown on the tablet.
public enum FileNaming {
    public static let maxLength = 120

    public static func visibleName(for document: ArticleDocument, prefixSourceName: Bool = false) -> String {
        var name = sanitize(document.title)
        if name.isEmpty {
            name = "Article"
        }
        if prefixSourceName, let source = document.sourceName.map(sanitize), !source.isEmpty {
            name = "\(source) – \(name)"
        }
        if name.count > maxLength {
            name = String(name.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return name
    }

    /// Removes characters that file systems and the tablet's UI dislike.
    public static func sanitize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", "\\", ":", "\u{0}"..."\u{1F}", "\u{7F}":
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        return HTMLDocumentBuilder.collapseWhitespace(String(scalars)).trimmingCharacters(in: .whitespaces)
    }
}
