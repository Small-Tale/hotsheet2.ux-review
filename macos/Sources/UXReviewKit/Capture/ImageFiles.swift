import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFileError: Error, Equatable, CustomStringConvertible {
    case cannotCreate(URL)
    case cannotWrite(URL)
    case unreadable(URL)

    public var description: String {
        switch self {
        case let .cannotCreate(url): "Cannot create an image file at \(url.path)"
        case let .cannotWrite(url): "Cannot write the image to \(url.path)"
        case let .unreadable(url): "Cannot read an image from \(url.path)"
        }
    }
}

/// PNG read/write via ImageIO (no AppKit).
public enum ImageFiles {
    public static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ImageFileError.cannotCreate(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageFileError.cannotWrite(url) }
    }

    /// Pixel size of an image file, read from its header.
    public static func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw ImageFileError.unreadable(url) }
        return (width, height)
    }

    /// `image` resampled to `size` with high-quality interpolation, keeping its color space
    /// (sRGB when it has none usable) and alpha. Nil for an empty size.
    public static func scaled(_ image: CGImage, to size: PixelSize) -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let space,
              let context = CGContext(
                  data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    public static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageFileError.unreadable(url) }
        return image
    }

    /// An sRGB test card: a diagonal gradient with a white frame, so crops and scaling are
    /// visible. Used by the synthetic capture backend and by tests; nil only for a zero size.
    public static func testCard(width: Int, height: Int, label: Int = 0) -> CGImage? {
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        let hue = Double(label % 12) / 12
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [
                CGColor(red: 0.15 + 0.5 * hue, green: 0.35, blue: 0.75 - 0.5 * hue, alpha: 1),
                CGColor(red: 0.95, green: 0.6 + 0.3 * hue, blue: 0.25, alpha: 1),
            ] as CFArray,
            locations: [0, 1]
        )
        if let gradient {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(CGFloat(max(min(width, height) / 50, 2)))
        context.stroke(CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: 2, dy: 2))
        return context.makeImage()
    }
}
