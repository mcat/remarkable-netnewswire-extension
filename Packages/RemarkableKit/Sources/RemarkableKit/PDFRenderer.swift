#if canImport(AppKit)
import AppKit
import CoreGraphics

public struct PDFRenderOptions: Equatable {
    public var pageSize: PageSizePreset = .remarkable2
    public var fontScale: Double = 1.0
    public var includeImages: Bool = true
    public var grayscaleImages: Bool = true
    /// Page margin in points.
    public var margin: Double = 30

    public init() {}

    public init(settings: SendSettings) {
        self.init()
        pageSize = settings.pageSize
        fontScale = settings.fontScale
        includeImages = settings.includeImages
        grayscaleImages = settings.grayscaleImages
    }
}

public enum PDFRenderError: Error, LocalizedError {
    case contextCreationFailed
    case layoutFailed

    public var errorDescription: String? {
        switch self {
        case .contextCreationFailed: return "Could not create the PDF."
        case .layoutFailed: return "Could not lay out the article."
        }
    }
}

public struct PDFRenderResult {
    public let data: Data
    public let pageCount: Int
    public let imageCount: Int
}

/// Renders an ``ArticleDocument`` into a paginated PDF sized for the tablet.
public enum PDFRenderer {
    public static func render(_ document: ArticleDocument, images: [URL: Data] = [:], options: PDFRenderOptions = PDFRenderOptions()) throws -> PDFRenderResult {
        let pageWidth = options.pageSize.widthPoints
        let pageHeight = options.pageSize.heightPoints
        let margin = options.margin
        let footerHeight = 18.0
        let contentSize = NSSize(width: pageWidth - 2 * margin, height: pageHeight - 2 * margin - footerHeight)
        guard contentSize.width > 50, contentSize.height > 50 else {
            throw PDFRenderError.layoutFailed
        }

        var builder = AttributedContentBuilder(options: options, contentSize: contentSize)
        let content = builder.build(document, images: images)

        // Lay the text out across as many page-sized containers as needed.
        let textStorage = NSTextStorage(attributedString: content)
        let layoutManager = NSLayoutManager()
        layoutManager.usesFontLeading = true
        textStorage.addLayoutManager(layoutManager)

        var containers: [NSTextContainer] = []
        let totalGlyphs = layoutManager.numberOfGlyphs
        var laidOut = 0
        while laidOut < totalGlyphs {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            let range = layoutManager.glyphRange(for: container)
            if range.length == 0 {
                break
            }
            laidOut = NSMaxRange(range)
            if containers.count >= 400 {
                break
            }
        }
        if containers.isEmpty {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
        }

        // Draw each container as a PDF page.
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw PDFRenderError.contextCreationFailed
        }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var metadata: [CFString: Any] = [
            kCGPDFContextTitle: document.title,
            kCGPDFContextCreator: "Send to reMarkable",
        ]
        if !document.authors.isEmpty {
            metadata[kCGPDFContextAuthor] = document.authors.joined(separator: ", ")
        }
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary) else {
            throw PDFRenderError.contextCreationFailed
        }

        let footerAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8 * options.fontScale),
            .foregroundColor: NSColor(white: 0.35, alpha: 1),
        ]
        let origin = NSPoint(x: margin, y: margin)

        for (pageIndex, container) in containers.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            // AppKit text drawing expects a flipped (top-left origin) coordinate system.
            context.translateBy(x: 0, y: pageHeight)
            context.scaleBy(x: 1, y: -1)

            let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext

            let glyphRange = layoutManager.glyphRange(for: container)
            if glyphRange.length > 0 {
                layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
                layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
            }

            let footer = "\(pageIndex + 1) / \(containers.count)" as NSString
            let footerSize = footer.size(withAttributes: footerAttributes)
            let footerPoint = NSPoint(x: (pageWidth - footerSize.width) / 2, y: pageHeight - margin - footerSize.height + 4)
            footer.draw(at: footerPoint, withAttributes: footerAttributes)

            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()

        return PDFRenderResult(data: data as Data, pageCount: containers.count, imageCount: builder.imageCount)
    }
}

// MARK: - Attributed string construction

struct AttributedContentBuilder {
    let options: PDFRenderOptions
    let contentSize: NSSize
    private(set) var imageCount = 0

    init(options: PDFRenderOptions, contentSize: NSSize) {
        self.options = options
        self.contentSize = contentSize
    }

    private var scale: Double { options.fontScale }

    // Fonts

    private func serif(_ size: Double, bold: Bool = false, italic: Bool = false) -> NSFont {
        let base = NSFont(name: "Georgia", size: size * scale) ?? NSFont.systemFont(ofSize: size * scale)
        return applyTraits(base, bold: bold, italic: italic)
    }

    private func sans(_ size: Double, weight: NSFont.Weight = .regular, italic: Bool = false) -> NSFont {
        let base = NSFont.systemFont(ofSize: size * scale, weight: weight)
        return italic ? applyTraits(base, bold: false, italic: true) : base
    }

    private func mono(_ size: Double) -> NSFont {
        NSFont(name: "Menlo", size: size * scale) ?? NSFont.monospacedSystemFont(ofSize: size * scale, weight: .regular)
    }

    private func applyTraits(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var result = font
        let manager = NSFontManager.shared
        if bold {
            result = manager.convert(result, toHaveTrait: .boldFontMask)
        }
        if italic {
            result = manager.convert(result, toHaveTrait: .italicFontMask)
        }
        return result
    }

    // Paragraph styles

    private func paragraphStyle(spacingBefore: Double = 0, spacing: Double = 6, firstLineIndent: Double = 0, headIndent: Double = 0,
                                alignment: NSTextAlignment = .natural, lineSpacing: Double = 1.5, tabLocation: Double? = nil,
                                lineBreak: NSLineBreakMode = .byWordWrapping) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore * scale
        style.paragraphSpacing = spacing * scale
        style.firstLineHeadIndent = firstLineIndent
        style.headIndent = headIndent
        style.alignment = alignment
        style.lineSpacing = lineSpacing * scale
        style.lineBreakMode = lineBreak
        style.hyphenationFactor = 0.8
        if let tabLocation {
            style.tabStops = [NSTextTab(textAlignment: .left, location: tabLocation, options: [:])]
            style.defaultTabInterval = tabLocation
        }
        return style
    }

    // Building

    mutating func build(_ document: ArticleDocument, images: [URL: Data]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        appendTitleBlock(document, to: result)

        for (index, block) in document.blocks.enumerated() {
            let isLast = index == document.blocks.count - 1
            switch block {
            case .paragraph(let runs):
                append(runs, font: serif(11.5), style: paragraphStyle(), to: result)
            case .heading(let level, let runs):
                let size: Double
                switch level {
                case 1: size = 18
                case 2: size = 16
                case 3: size = 14
                default: size = 12.5
                }
                append(runs, font: sans(size, weight: .bold), style: paragraphStyle(spacingBefore: 12, spacing: 4, lineSpacing: 1), to: result)
            case .listItem(let ordered, let itemIndex, let depth, let showsMarker, let runs):
                let unit = 18.0 * scale
                let headIndent = unit * Double(max(1, depth))
                let firstLine = showsMarker ? headIndent - unit : headIndent
                let style = paragraphStyle(spacing: 3, firstLineIndent: firstLine, headIndent: headIndent, tabLocation: headIndent)
                var prefixed = runs
                if showsMarker {
                    let marker = ordered ? "\(itemIndex).\t" : "•\t"
                    prefixed.insert(InlineRun(marker), at: 0)
                }
                append(prefixed, font: serif(11.5), style: style, to: result)
            case .quote(let depth, let runs):
                let indent = 16.0 * scale * Double(max(1, depth))
                append(runs, font: serif(11, italic: true), style: paragraphStyle(firstLineIndent: indent, headIndent: indent), color: NSColor(white: 0.15, alpha: 1), to: result)
            case .caption(let runs):
                append(runs, font: sans(9.5, italic: true), style: paragraphStyle(spacingBefore: 0, spacing: 10, alignment: .center, lineSpacing: 1), color: NSColor(white: 0.3, alpha: 1), to: result)
            case .code(let text):
                let style = paragraphStyle(spacingBefore: 4, spacing: 8, firstLineIndent: 8, headIndent: 8, lineSpacing: 1, lineBreak: .byCharWrapping)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: mono(8.8),
                    .paragraphStyle: style,
                    .foregroundColor: NSColor.black,
                    .backgroundColor: NSColor(white: 0.93, alpha: 1),
                ]
                result.append(NSAttributedString(string: text + "\n", attributes: attributes))
            case .image(let ref):
                guard options.includeImages else { continue }
                let bytes = ref.data ?? ref.url.flatMap { images[$0] }
                guard let bytes, let attachment = makeAttachment(from: bytes) else { continue }
                imageCount += 1
                let imageString = NSMutableAttributedString(attributedString: NSAttributedString(attachment: attachment))
                imageString.append(NSAttributedString(string: "\n"))
                imageString.addAttribute(.paragraphStyle, value: paragraphStyle(spacingBefore: 6, spacing: 8, alignment: .center, lineSpacing: 0), range: NSRange(location: 0, length: imageString.length))
                result.append(imageString)
            case .rule:
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: serif(11),
                    .paragraphStyle: paragraphStyle(spacingBefore: 6, spacing: 10, alignment: .center),
                    .foregroundColor: NSColor(white: 0.4, alpha: 1),
                ]
                result.append(NSAttributedString(string: "•   •   •\n", attributes: attributes))
            }
            if isLast, result.string.hasSuffix("\n") {
                result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
            }
        }
        return result
    }

    private func appendTitleBlock(_ document: ArticleDocument, to result: NSMutableAttributedString) {
        let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: sans(21, weight: .bold),
            .paragraphStyle: paragraphStyle(spacing: 6, lineSpacing: 1),
            .foregroundColor: NSColor.black,
        ]
        result.append(NSAttributedString(string: (title.isEmpty ? "Untitled" : title) + "\n", attributes: titleAttributes))

        let byline = document.byline
        if !byline.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: sans(10),
                .paragraphStyle: paragraphStyle(spacing: 2, lineSpacing: 1),
                .foregroundColor: NSColor(white: 0.25, alpha: 1),
            ]
            result.append(NSAttributedString(string: byline + "\n", attributes: attributes))
        }
        if let url = document.url {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: sans(8.5),
                .paragraphStyle: paragraphStyle(spacing: 14, lineSpacing: 1, lineBreak: .byCharWrapping),
                .foregroundColor: NSColor(white: 0.4, alpha: 1),
            ]
            result.append(NSAttributedString(string: url.absoluteString + "\n", attributes: attributes))
        } else {
            let spacer: [NSAttributedString.Key: Any] = [
                .font: sans(4),
                .paragraphStyle: paragraphStyle(spacing: 10, lineSpacing: 0),
            ]
            result.append(NSAttributedString(string: "\n", attributes: spacer))
        }
    }

    private func append(_ runs: [InlineRun], font: NSFont, style: NSParagraphStyle, color: NSColor = .black, to result: NSMutableAttributedString) {
        let paragraph = NSMutableAttributedString()
        for run in runs {
            var runFont = font
            if run.style.contains(.code) {
                runFont = mono(font.pointSize / scale * 0.88)
            } else if run.style.contains(.bold) || run.style.contains(.italic) {
                runFont = applyTraits(font, bold: run.style.contains(.bold), italic: run.style.contains(.italic))
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
            if run.style.contains(.code) {
                attributes[.backgroundColor] = NSColor(white: 0.93, alpha: 1)
            }
            paragraph.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        guard paragraph.length > 0 else { return }
        paragraph.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        result.append(paragraph)
    }

    private func makeAttachment(from data: Data) -> NSTextAttachment? {
        guard let prepared = ImageProcessing.prepare(data, maxPixelWidth: options.pageSize.pixelWidth, grayscale: options.grayscaleImages) else {
            return nil
        }
        let maxWidth = contentSize.width
        let maxHeight = contentSize.height * 0.62
        let pixelWidth = Double(prepared.pixelWidth)
        let pixelHeight = Double(prepared.pixelHeight)

        // Large images fill the column; small ones keep a natural size.
        var width = pixelWidth >= 400 ? maxWidth : min(maxWidth, pixelWidth * 72.0 / 150.0)
        var height = width * pixelHeight / pixelWidth
        if height > maxHeight {
            height = maxHeight
            width = height * pixelWidth / pixelHeight
        }
        let size = NSSize(width: width.rounded(.down), height: height.rounded(.down))
        guard size.width >= 1, size.height >= 1 else { return nil }

        let attachment = NSTextAttachment()
        attachment.attachmentCell = ImageAttachmentCell(image: prepared.image, size: size)
        return attachment
    }
}

/// Draws an image attachment respecting the flipped PDF context.
final class ImageAttachmentCell: NSTextAttachmentCell {
    private let renderImage: NSImage
    private let renderSize: NSSize

    init(image: NSImage, size: NSSize) {
        renderImage = image
        renderSize = size
        super.init(imageCell: image)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cellSize() -> NSSize {
        renderSize
    }

    override func cellBaselineOffset() -> NSPoint {
        .zero
    }

    private func drawImage(in cellFrame: NSRect) {
        renderImage.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        drawImage(in: cellFrame)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        drawImage(in: cellFrame)
    }
}
#endif
