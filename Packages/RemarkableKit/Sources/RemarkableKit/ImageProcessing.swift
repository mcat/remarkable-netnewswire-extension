#if canImport(AppKit)
import AppKit
import CoreGraphics

/// Decodes and normalizes images for e-ink rendering.
public enum ImageProcessing {
    public struct PreparedImage {
        public let image: NSImage
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// Decodes `data`, downsizes it to at most `maxPixelWidth`, flattens
    /// transparency onto white and optionally converts to 8-bit grayscale.
    /// Returns nil for undecodable or tiny (icon-sized) images.
    public static func prepare(_ data: Data, maxPixelWidth: Int, grayscale: Bool, minimumDimension: Int = 24) -> PreparedImage? {
        guard let source = NSImage(data: data),
              let cgSource = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let width = cgSource.width
        let height = cgSource.height
        guard width >= minimumDimension, height >= minimumDimension else { return nil }

        let scale = min(1.0, Double(max(1, maxPixelWidth)) / Double(width))
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))

        let colorSpace = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        let rect = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(cgSource, in: rect)
        guard let output = context.makeImage() else { return nil }

        let image = NSImage(cgImage: output, size: NSSize(width: targetWidth, height: targetHeight))
        return PreparedImage(image: image, pixelWidth: targetWidth, pixelHeight: targetHeight)
    }
}
#endif
