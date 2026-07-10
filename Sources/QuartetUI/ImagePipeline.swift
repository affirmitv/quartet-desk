import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
import QuartetEngine

enum ImagePipelineError: Error, LocalizedError {
    case undecodable
    case encodeFailed
    case cannotFitUnderByteLimit(bytes: Int)

    var errorDescription: String? {
        switch self {
        case .undecodable:
            return "The dropped/pasted data is not a decodable image."
        case .encodeFailed:
            return "JPEG re-encoding failed."
        case .cannotFitUnderByteLimit(let bytes):
            return "Image could not be compressed under \(Limits.imageMaxBytes / (1024 * 1024))MB (best attempt: \(bytes / 1024)KB)."
        }
    }
}

/// Downscales to ≤2048px on the long side and re-encodes as JPEG ≤4MB.
/// Pure ImageIO/CoreGraphics — safe off the main actor.
enum ImagePipeline {
    private static let logger = Logger(subsystem: "tv.affirmi.quartetdesk", category: "images")

    static func process(_ data: Data) throws -> ImageAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw ImagePipelineError.undecodable
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: Limits.imageMaxPixelLongSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImagePipelineError.undecodable
        }

        var lastSize = 0
        for quality in [0.85, 0.7, 0.55, 0.4, 0.3] {
            let encoded = try encodeJPEG(image, quality: quality)
            lastSize = encoded.count
            if encoded.count <= Limits.imageMaxBytes {
                return ImageAttachment(base64Data: encoded.base64EncodedString(), mediaType: "image/jpeg")
            }
        }
        logger.error("Image could not be compressed under limit; best attempt \(lastSize) bytes")
        throw ImagePipelineError.cannotFitUnderByteLimit(bytes: lastSize)
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImagePipelineError.encodeFailed
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImagePipelineError.encodeFailed
        }
        return output as Data
    }
}
