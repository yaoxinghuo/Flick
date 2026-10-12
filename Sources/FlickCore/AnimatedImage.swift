import CoreGraphics
import Foundation
import ImageIO

/// A decoded animated image (GIF, APNG, animated WebP): every frame plus its
/// display delay. Playback is a layer-level `CAKeyframeAnimation`, so it never
/// stutters under zoom or rotation.
public struct AnimatedImage {
    public let frames: [CGImage]
    public let delays: [TimeInterval]
    public let size: CGSize

    public var frameCount: Int { frames.count }
    public var duration: TimeInterval { delays.reduce(0, +) }

    /// Normalized cumulative key times (0…1) for `CAKeyframeAnimation`.
    public var keyTimes: [NSNumber] {
        let total = duration
        guard total > 0 else { return frames.map { _ in 0 } }
        var acc = 0.0
        return delays.map { delay in
            acc += delay / total
            return NSNumber(value: acc)
        }
    }
}

public enum AnimatedImageDecoder {
    /// UTIs that may contain multi-frame animation.
    private static let animatedTypeIDs: Set<String> = [
        "com.compuserve.gif",
        "public.png",             // APNG reports as public.png
        "org.webmproject.webp",
    ]

    /// Whether this source could contain animation (type + frame count).
    public static func isAnimatedSource(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 1,
              let type = CGImageSourceGetType(source) as? String else {
            return false
        }
        return animatedTypeIDs.contains(type)
    }

    /// Decodes every frame and its delay. `nil` when the source isn't animated.
    public static func decode(source: CGImageSource) -> AnimatedImage? {
        guard isAnimatedSource(source),
              let type = CGImageSourceGetType(source) as? String else {
            return nil
        }
        let frameCount = CGImageSourceGetCount(source)
        var frames: [CGImage] = []
        var delays: [TimeInterval] = []
        frames.reserveCapacity(frameCount)
        delays.reserveCapacity(frameCount)
        var size = CGSize.zero

        for index in 0..<frameCount {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options) else {
                continue
            }
            frames.append(frame)
            if index == 0 {
                size = CGSize(width: frame.width, height: frame.height)
            }
            delays.append(delay(at: index, in: source, type: type))
        }
        guard frames.count > 1 else { return nil }
        return AnimatedImage(frames: frames, delays: delays, size: size)
    }

    /// Per-frame delay with the browser-standard 20ms floor for (near-)zero
    /// delays. Frame properties live in the format's own property dictionary
    /// ("{GIF}", "{PNG}", "{WebP}") — not keyed by the file's UTI.
    private static func delay(at index: Int, in source: CGImageSource, type: String) -> TimeInterval {
        let dictKey: CFString
        let delayKeys: [CFString]
        switch type {
        case "com.compuserve.gif":
            dictKey = kCGImagePropertyGIFDictionary
            delayKeys = [kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime]
        case "public.png":
            dictKey = kCGImagePropertyPNGDictionary
            delayKeys = [kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime]
        default:
            dictKey = kCGImagePropertyWebPDictionary
            delayKeys = [kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime]
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let typeDict = props[dictKey] as? [CFString: Any] else {
            return 0.1
        }
        for key in delayKeys {
            if let value = typeDict[key] as? Double {
                return max(value, 0.02)
            }
        }
        return 0.1
    }
}
