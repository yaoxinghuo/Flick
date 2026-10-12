import CoreGraphics
import Foundation

/// Lossless quarter-turn rotation of decoded pixels (view-only, never written
/// back to disk).
public enum ImageRotator {
    /// Returns `image` rotated clockwise by `quarterTurns` × 90°.
    public static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }

        let w = image.width, h = image.height
        let (dw, dh) = turns % 2 == 1 ? (h, w) : (w, h)
        guard let context = CGContext(
            data: nil,
            width: dw,
            height: dh,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return image
        }

        // In CG's y-up space, a screen-clockwise turn is a negative rotation.
        switch turns {
        case 1: // 90° clockwise
            context.translateBy(x: 0, y: CGFloat(dh))
            context.rotate(by: -.pi / 2)
        case 2: // 180°
            context.translateBy(x: CGFloat(dw), y: CGFloat(dh))
            context.rotate(by: .pi)
        default: // 3: 90° counter-clockwise
            context.translateBy(x: CGFloat(dw), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage() ?? image
    }
}
