#if canImport(AppKit)
import AppKit

/// What the share sheet handed us, in order of preference.
public enum SharedInput {
    case article(NetNewsWireArticle)
    case html(String, url: URL?, title: String?)
    case url(URL)
    case text(String)
}

/// Progress reported while an article is sent.
public enum SendProgress: Equatable {
    case preparing
    case fetchingPage
    case fetchingImages(completed: Int, total: Int)
    case rendering
    case uploading(name: String)
    case done(name: String)

    public var message: String {
        switch self {
        case .preparing: return "Preparing article…"
        case .fetchingPage: return "Downloading page…"
        case .fetchingImages(let completed, let total): return "Downloading images (\(completed) of \(total))…"
        case .rendering: return "Laying out pages…"
        case .uploading(let name): return "Sending “\(name)”…"
        case .done(let name): return "Sent “\(name)” to your reMarkable."
        }
    }
}

public struct SendResult {
    public let name: String
    public let pageCount: Int
    public let imageCount: Int
    public let pdfData: Data
}

public enum SendPipelineError: Error, LocalizedError {
    case emptyArticle
    case pageDownloadFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyArticle: return "The shared item contained no readable article."
        case .pageDownloadFailed(let url): return "Could not download \(url.absoluteString)."
        }
    }
}

/// Turns a shared item into a PDF and delivers it to the tablet.
public final class SendPipeline {
    public let settings: SendSettings
    public let tokenStore: TokenStore
    public let cloudClient: RemarkableCloudClient
    public let imageFetcher: ImageFetcher

    public init(settings: SendSettings, tokenStore: TokenStore, cloudClient: RemarkableCloudClient = RemarkableCloudClient(), imageFetcher: ImageFetcher = ImageFetcher()) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.cloudClient = cloudClient
        self.imageFetcher = imageFetcher
    }

    public func send(_ input: SharedInput, progress: @escaping @Sendable (SendProgress) -> Void) async throws -> SendResult {
        progress(.preparing)
        let document = try await makeDocument(from: input, progress: progress)
        let rendered = try await render(document, progress: progress)
        let name = FileNaming.visibleName(for: document, prefixSourceName: settings.prefixSourceName)
        progress(.uploading(name: name))
        try await upload(pdf: rendered.data, name: name)
        progress(.done(name: name))
        return SendResult(name: name, pageCount: rendered.pageCount, imageCount: rendered.imageCount, pdfData: rendered.data)
    }

    public func makeDocument(from input: SharedInput, progress: @escaping @Sendable (SendProgress) -> Void) async throws -> ArticleDocument {
        let document: ArticleDocument
        switch input {
        case .article(let article):
            document = article.makeDocument()
        case .html(let html, let url, let title):
            document = WebPageExtractor.document(fromPage: html, url: url, titleHint: title)
        case .url(let url):
            progress(.fetchingPage)
            let html = try await SendPipeline.downloadPage(url)
            document = WebPageExtractor.document(fromPage: html, url: url)
        case .text(let text):
            document = ArticleDocumentFactory.document(fromPlainText: text)
        }
        guard !document.blocks.isEmpty || !document.title.isEmpty else {
            throw SendPipelineError.emptyArticle
        }
        return document
    }

    public func render(_ document: ArticleDocument, progress: @escaping @Sendable (SendProgress) -> Void) async throws -> PDFRenderResult {
        var images: [URL: Data] = [:]
        if settings.includeImages {
            let urls = Array(document.remoteImageURLs.prefix(settings.maxImages))
            if !urls.isEmpty {
                progress(.fetchingImages(completed: 0, total: urls.count))
                var fetcher = imageFetcher
                fetcher.maxCount = settings.maxImages
                images = await fetcher.fetch(urls) { completed, total in
                    progress(.fetchingImages(completed: completed, total: total))
                }
            }
        }
        progress(.rendering)
        let options = PDFRenderOptions(settings: settings)
        return try PDFRenderer.render(document, images: images, options: options)
    }

    public func upload(pdf: Data, name: String) async throws {
        switch settings.transport {
        case .cloud:
            let uploader = CloudUploader(client: cloudClient, store: tokenStore)
            try await uploader.upload(data: pdf, fileName: name)
        case .usb:
            let client = RemarkableUSBClient(host: settings.usbHost)
            try await client.upload(data: pdf, fileName: name + ".pdf")
        }
    }

    // MARK: - Helpers

    static func downloadPage(_ url: URL) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            "Accept": "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
        ]
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SendPipelineError.pageDownloadFailed(url)
        }
        if let encodingName = response.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: data, encoding: encoding) {
                    return text
                }
            }
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let text = String(data: data, encoding: .windowsCP1252) {
            return text
        }
        throw SendPipelineError.pageDownloadFailed(url)
    }

    /// A short document used by the app's "Send a test page" button.
    public static func sampleDocument() -> ArticleDocument {
        let html = """
        <p>This page was generated by <strong>Send to reMarkable</strong>, the NetNewsWire share extension. \
        If you can read it on your tablet, the connection works.</p>
        <h2>What gets sent</h2>
        <ul><li>Article text with <em>basic</em> formatting, headings, lists and quotes.</li>\
        <li>Images, downscaled and converted to grayscale for e-ink.</li>\
        <li>A title block with the author, source and date.</li></ul>
        <blockquote>Select an article in NetNewsWire, click Share, then choose “Send to reMarkable”.</blockquote>
        <pre><code>let ready = true</code></pre>
        """
        let blocks = HTMLDocumentBuilder.blocks(fromHTML: html)
        return ArticleDocument(title: "Send to reMarkable is set up", authors: ["Send to reMarkable"], sourceName: "NetNewsWire", url: nil, date: Date(), blocks: blocks)
    }
}
#endif
