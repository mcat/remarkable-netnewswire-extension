import AppKit
import RemarkableKit
import UniformTypeIdentifiers

/// Extracts the most useful representation of what was shared.
enum ShareInputReader {
    enum ReadError: Error, LocalizedError {
        case nothingShareable

        var errorDescription: String? {
            "Nothing shareable was found. Share an article, a web page or a link."
        }
    }

    static func read(from context: NSExtensionContext) async throws -> SharedInput {
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        let providers = items.flatMap { $0.attachments ?? [] }
        let titleHint = items.compactMap { $0.attributedTitle?.string }.first { !$0.isEmpty }

        // 1. A NetNewsWire article, with the original feed HTML and metadata.
        if let provider = firstProvider(in: providers, for: NetNewsWireArticle.typeIdentifier) {
            let item = try? await load(provider, type: NetNewsWireArticle.typeIdentifier)
            if let article = article(from: item) {
                return .article(article)
            }
        }

        // 2. A URL, possibly accompanied by HTML.
        var url: URL?
        if let provider = firstProvider(in: providers, for: UTType.url.identifier) {
            url = self.url(from: try? await load(provider, type: UTType.url.identifier))
        }
        if let provider = firstProvider(in: providers, for: UTType.html.identifier),
           let html = string(from: try? await load(provider, type: UTType.html.identifier)),
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .html(html, url: url, title: titleHint)
        }
        if let url, url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            return .url(url)
        }

        // 3. Plain text.
        if let provider = firstProvider(in: providers, for: UTType.plainText.identifier),
           let text = string(from: try? await load(provider, type: UTType.plainText.identifier)),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        if let text = items.compactMap({ $0.attributedContentText?.string }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return .text(text)
        }
        throw ReadError.nothingShareable
    }

    // MARK: - Helpers

    private static func firstProvider(in providers: [NSItemProvider], for type: String) -> NSItemProvider? {
        providers.first { provider in
            provider.hasItemConformingToTypeIdentifier(type) || provider.registeredTypeIdentifiers.contains(type)
        }
    }

    private static func load(_ provider: NSItemProvider, type: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSSecureCoding?, Error>) in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }

    private static func article(from item: NSSecureCoding?) -> NetNewsWireArticle? {
        guard let item else { return nil }
        if let dictionary = item as? NSDictionary, let bridged = dictionary as? [String: Any] {
            return NetNewsWireArticle(dictionary: bridged)
        }
        if let data = item as? Data {
            return NetNewsWireArticle(propertyListData: data)
        }
        return nil
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        guard let item else { return nil }
        if let url = item as? URL {
            return url
        }
        if let text = string(from: item)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return URL(string: text)
        }
        return nil
    }

    private static func string(from item: NSSecureCoding?) -> String? {
        guard let item else { return nil }
        if let text = item as? String {
            return text
        }
        if let attributed = item as? NSAttributedString {
            return attributed.string
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        }
        if let url = item as? URL {
            return url.absoluteString
        }
        return nil
    }
}
