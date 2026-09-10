#if canImport(AppKit)
import XCTest
import PDFKit
@testable import RemarkableKit

final class PDFRenderingTests: XCTestCase {
    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let cgImage = try XCTUnwrap(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testRendersMultiPagePDFWithImages() throws {
        let imageURL = URL(string: "https://example.com/big.png")!
        var blocks: [Block] = [.image(ImageRef(url: imageURL, alt: "hero"))]
        for i in 1...80 {
            blocks.append(.paragraph([InlineRun("Paragraph \(i). "), InlineRun("Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.", style: i % 2 == 0 ? [.italic] : [])]))
            if i % 10 == 0 {
                blocks.append(.heading(level: 2, [InlineRun("Section \(i / 10)")]))
                blocks.append(.listItem(ordered: true, index: 1, depth: 1, showsMarker: true, [InlineRun("Item one")]))
                blocks.append(.quote(depth: 1, [InlineRun("A quotation")]))
                blocks.append(.code("let x = 1\nprint(x)"))
                blocks.append(.rule)
            }
        }
        blocks.append(.image(ImageRef(data: try makePNG(width: 300, height: 200))))
        let document = ArticleDocument(title: "Rendering test", authors: ["Tester"], sourceName: "example.com", url: URL(string: "https://example.com/post"), date: Date(), blocks: blocks)

        let images = [imageURL: try makePNG(width: 1600, height: 900)]
        let result = try PDFRenderer.render(document, images: images)

        XCTAssertGreaterThan(result.pageCount, 1)
        XCTAssertEqual(result.imageCount, 2)
        let pdf = try XCTUnwrap(PDFDocument(data: result.data))
        XCTAssertEqual(pdf.pageCount, result.pageCount)
        let first = try XCTUnwrap(pdf.page(at: 0))
        let bounds = first.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, PageSizePreset.remarkable2.widthPoints, accuracy: 0.5)
        XCTAssertEqual(bounds.height, PageSizePreset.remarkable2.heightPoints, accuracy: 0.5)
        XCTAssertTrue(first.string?.contains("Rendering test") ?? false)
        XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Rendering test")
    }

    func testTinyAndUndecodableImagesAreSkipped() throws {
        XCTAssertNil(ImageProcessing.prepare(Data("not an image".utf8), maxPixelWidth: 1000, grayscale: true))
        XCTAssertNil(ImageProcessing.prepare(try makePNG(width: 8, height: 8), maxPixelWidth: 1000, grayscale: true))
        let prepared = try XCTUnwrap(ImageProcessing.prepare(try makePNG(width: 2000, height: 1000), maxPixelWidth: 1000, grayscale: true))
        XCTAssertEqual(prepared.pixelWidth, 1000)
        XCTAssertEqual(prepared.pixelHeight, 500)
    }

    func testSampleDocumentRenders() throws {
        let result = try PDFRenderer.render(SendPipeline.sampleDocument())
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertTrue(result.data.starts(with: Data("%PDF".utf8)))
    }
}
#endif
