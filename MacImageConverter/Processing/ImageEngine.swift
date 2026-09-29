import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum ImageError: LocalizedError, Equatable {
    case unsupported, cannotDecode, cannotRender, cannotEncode, invalidSize, invalidMaximumSize, sizeLimitUnreachable, outputUnavailable, insufficientResources

    var errorDescription: String? {
        switch self {
        case .unsupported: "Unsupported image format. Choose PNG, JPEG, or WebP."
        case .cannotDecode: "The image could not be decoded. It may be damaged."
        case .cannotRender: "The image could not be processed. Try a smaller output size."
        case .cannotEncode: "The output image could not be encoded."
        case .invalidSize: "Width and height must be positive pixel values."
        case .invalidMaximumSize: "Maximum file size must be a positive number of KB."
        case .sizeLimitUnreachable: "The size limit cannot be met at the minimum quality. Increase the limit, lower minimum quality, or reduce dimensions."
        case .outputUnavailable: "Choose an available output folder."
        case .insufficientResources: "The requested output is too large to process safely. Reduce its dimensions."
        }
    }
}

enum ImageEngine {
    static func inspect(_ url: URL) throws -> ImageAsset {
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let format: String
        let width: Int
        let height: Int
        let thumbnail: CGImage
        if let source, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
           let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
           let type = CGImageSourceGetType(source) as String? {
            guard [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(type) else { throw ImageError.unsupported }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            width = (5...8).contains(orientation) ? pixelHeight : pixelWidth
            height = (5...8).contains(orientation) ? pixelWidth : pixelHeight
            format = type == UTType.png.identifier ? "PNG" : type == UTType.jpeg.identifier ? "JPEG" : "WebP"
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                           kCGImageSourceCreateThumbnailWithTransform: true,
                           kCGImageSourceThumbnailMaxPixelSize: 112] as CFDictionary
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
                thumbnail = image
            } else if type == UTType.webP.identifier {
                thumbnail = try decodeWebPScaled(Data(contentsOf: url, options: .mappedIfSafe), maxDimension: 112)
            } else { throw ImageError.cannotDecode }
        } else if url.pathExtension.lowercased() == "webp" {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            var w: Int32 = 0, h: Int32 = 0
            guard data.withUnsafeBytes({ WebPGetInfo($0.bindMemory(to: UInt8.self).baseAddress, data.count, &w, &h) }) != 0,
                  w > 0, h > 0 else { throw ImageError.cannotDecode }
            width = Int(w); height = Int(h); format = "WebP"
            thumbnail = try decodeWebPScaled(data, maxDimension: 112)
        } else { throw ImageError.unsupported }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return ImageAsset(url: url, width: width, height: height, byteCount: size,
                          format: format, thumbnail: NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height)))
    }

    static func process(_ url: URL, settings: ProcessingSettings, previewLimit: Int? = nil) throws -> CGImage {
        guard settings.width == nil || settings.width! > 0,
              settings.height == nil || settings.height! > 0 else { throw ImageError.invalidSize }
        if previewLimit == nil {
            let sourceSize = try dimensions(url)
            guard Int64(sourceSize.0) * Int64(sourceSize.1) <= 100_000_000 else { throw ImageError.insufficientResources }
        }
        let sourceImage = try decode(url, previewLimit: previewLimit)
        var effectiveSettings = settings
        if let limit = previewLimit {
            // Apply the same pipeline at a screen-sized scale; output geometry is scaled as well.
            let properties = try dimensions(url)
            let ratio = min(1, Double(limit) / Double(max(properties.0, properties.1)))
            effectiveSettings.width = settings.width.map { max(1, Int((Double($0) * ratio).rounded())) }
            effectiveSettings.height = settings.height.map { max(1, Int((Double($0) * ratio).rounded())) }
        }
        let plan = ResizePlan.make(sourceWidth: sourceImage.width, sourceHeight: sourceImage.height, settings: effectiveSettings)
        guard plan.width <= 32768, plan.height <= 32768,
              Int64(plan.width) * Int64(plan.height) <= 100_000_000 else { throw ImageError.insufficientResources }
        let resized = try render(sourceImage, plan: plan)
        return try applyBackground(resized, settings: settings)
    }

    static func encode(_ image: CGImage, sourceURL: URL, settings: ProcessingSettings,
                       sourceByteCount: Int64? = nil) throws -> Data {
        if settings.compressionMode == .maximumSize && !(1...1_048_576).contains(settings.maximumSizeKiB) {
            throw ImageError.invalidMaximumSize
        }
        let maximumBytes: Int64? = settings.compressionMode == .maximumSize
            ? Int64(settings.maximumSizeKiB) * 1024 : nil
        if settings.format == .webp && settings.webpLossless {
            let data = try encodeWebP(image, quality: settings.quality, lossless: true)
            if let maximumBytes, Int64(data.count) > maximumBytes { throw ImageError.sizeLimitUnreachable }
            return data
        }
        let properties = metadataProperties(sourceURL: sourceURL, settings: settings)
        if settings.format == .png {
            let normal = try encodeWithImageIO(image, format: .png, quality: nil, properties: properties, pngFilter: nil)
            guard settings.compressionMode != .manual else { return normal }
            var smallest = normal
            // PNG filters are lossless. Different images compress best with different filters.
            for filter in [0xF8, 0x80, 0x08] {
                try checkCancellation()
                let candidate = try encodeWithImageIO(image, format: .png, quality: nil,
                                                      properties: properties, pngFilter: filter)
                if candidate.count < smallest.count { smallest = candidate }
            }
            if let maximumBytes, Int64(smallest.count) > maximumBytes { throw ImageError.sizeLimitUnreachable }
            return smallest
        }
        let encodeAtQuality: (Int) throws -> Data = { quality in
            if settings.format == .webp {
                return try encodeWebP(image, quality: quality, lossless: false)
            }
            return try encodeWithImageIO(image, format: .jpeg, quality: quality,
                                         properties: properties, pngFilter: nil)
        }
        guard settings.compressionMode != .manual else {
            return try encodeAtQuality(settings.quality)
        }
        let originalBytes = sourceByteCount ?? (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let reduction = min(95, max(0, settings.targetReductionPercent))
        let targetBytes = maximumBytes ?? Int64(Double(originalBytes) * (1 - Double(reduction) / 100))
        if maximumBytes == nil && originalBytes <= 0 { return try encodeAtQuality(settings.quality) }
        let floorQuality = min(100, max(1, settings.minimumQuality))

        // Try maximum quality first. If it already fits, no visual quality is sacrificed.
        let maximum = try encodeAtQuality(100)
        if Int64(maximum.count) <= targetBytes { return maximum }
        if floorQuality == 100 {
            if maximumBytes != nil { throw ImageError.sizeLimitUnreachable }
            return maximum
        }
        var smallest = maximum
        var bestWithinTarget: Data?
        var low = floorQuality
        var high = 99
        while low <= high {
            try checkCancellation()
            let quality = (low + high) / 2
            let candidate = try encodeAtQuality(quality)
            if candidate.count < smallest.count { smallest = candidate }
            if Int64(candidate.count) <= targetBytes {
                bestWithinTarget = candidate
                low = quality + 1
            } else {
                high = quality - 1
            }
        }
        if let bestWithinTarget { return bestWithinTarget }
        if maximumBytes != nil { throw ImageError.sizeLimitUnreachable }
        return smallest
    }

    static func decodeOutput(_ data: Data, format: OutputFormat) throws -> CGImage {
        if format == .webp { return try decodeWebP(data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageError.cannotDecode }
        return image
    }

    static func preview(_ url: URL, settings: ProcessingSettings, limit: Int) throws -> CGImage {
        let processed = try process(url, settings: settings, previewLimit: limit)
        let sourceDimensions = try dimensions(url)
        let fullPlan = ResizePlan.make(sourceWidth: sourceDimensions.0, sourceHeight: sourceDimensions.1,
                                       settings: settings)
        let fullPixels = Double(fullPlan.width) * Double(fullPlan.height)
        let previewPixels = Double(processed.width) * Double(processed.height)
        let fileBytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let previewBudget = max(1, Int64(Double(fileBytes) * min(1, previewPixels / max(1, fullPixels))))
        var previewSettings = settings
        if settings.compressionMode == .maximumSize {
            // An impossible thumbnail budget should not suppress the visual preview.
            previewSettings.compressionMode = .automatic
            previewSettings.targetReductionPercent = fileBytes > 0
                ? min(95, max(0, Int((1 - Double(settings.maximumSizeKiB) * 1024 / Double(fileBytes)) * 100))) : 0
        }
        let encoded = try encode(processed, sourceURL: url, settings: previewSettings,
                                 sourceByteCount: previewBudget)
        return try decodeOutput(encoded, format: settings.format)
    }

    private static func metadataProperties(sourceURL: URL, settings: ProcessingSettings) -> [CFString: Any] {
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        if !settings.stripMetadata,
           let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyIPTCDictionary,
                        kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary] {
                properties[key] = original[key]
            }
        }
        return properties
    }

    private static func encodeWithImageIO(_ image: CGImage, format: OutputFormat, quality: Int?,
                                          properties: [CFString: Any], pngFilter: Int?) throws -> Data {
        let data = NSMutableData()
        let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw ImageError.cannotEncode }
        var outputProperties = properties
        if let quality {
            outputProperties[kCGImageDestinationLossyCompressionQuality] = Double(min(100, max(0, quality))) / 100
        }
        if let pngFilter {
            outputProperties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGCompressionFilter: pngFilter]
        }
        CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError.cannotEncode }
        return data as Data
    }

    private static func checkCancellation() throws {
        if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { throw CancellationError() }
    }

    static func dimensions(_ url: URL) throws -> (Int, Int) {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int { return (w, h) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var w: Int32 = 0, h: Int32 = 0
        guard data.withUnsafeBytes({ WebPGetInfo($0.bindMemory(to: UInt8.self).baseAddress, data.count, &w, &h) }) != 0 else { throw ImageError.cannotDecode }
        return (Int(w), Int(h))
    }

    private static func decode(_ url: URL, previewLimit: Int?) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let type = CGImageSourceGetType(source) as String?,
           [UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(type) {
            if let previewLimit {
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceCreateThumbnailWithTransform: true,
                               kCGImageSourceThumbnailMaxPixelSize: previewLimit] as CFDictionary
                if let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) { return thumbnail }
            }
            if let raw = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) {
                let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
                if orientation == 1 { return raw }
                let ci = CIImage(cgImage: raw).oriented(forExifOrientation: Int32(orientation))
                guard let normalized = CIContext().createCGImage(ci, from: ci.extent) else { throw ImageError.cannotRender }
                return normalized
            }
        }
        guard url.pathExtension.lowercased() == "webp" else { throw ImageError.cannotDecode }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if let previewLimit { return try decodeWebPScaled(data, maxDimension: previewLimit) }
        return try decodeWebP(data)
    }

    private static func render(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        try render(image, plan: ResizePlan(width: width, height: height, drawWidth: Double(width), drawHeight: Double(height)))
    }

    private static func render(_ image: CGImage, plan: ResizePlan) throws -> CGImage {
        guard let context = CGContext(data: nil, width: plan.width, height: plan.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ImageError.cannotRender }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(plan.width) - plan.drawWidth) / 2,
                                       y: (Double(plan.height) - plan.drawHeight) / 2,
                                       width: plan.drawWidth, height: plan.drawHeight))
        guard let result = context.makeImage() else { throw ImageError.cannotRender }
        return result
    }

    private static func applyBackground(_ image: CGImage, settings: ProcessingSettings) throws -> CGImage {
        if settings.removalColor == nil && settings.format != .jpeg { return image }
        let width = image.width, height = image.height, rowBytes = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: rowBytes, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { throw ImageError.cannotRender }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: rowBytes * height)
        let removal = settings.removalColor
        let tolerance = min(1, max(0, settings.tolerance / 100))
        let softness = min(1, max(0, settings.edgeSoftness / 100))
        let low = max(0, tolerance - softness / 2)
        let high = min(1, tolerance + softness / 2)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let oldAlpha = Double(pixels[offset + 3]) / 255
            if oldAlpha <= 0 {
                if settings.format == .jpeg {
                    pixels[offset] = UInt8((settings.jpegBackground.red * 255).rounded())
                    pixels[offset + 1] = UInt8((settings.jpegBackground.green * 255).rounded())
                    pixels[offset + 2] = UInt8((settings.jpegBackground.blue * 255).rounded())
                    pixels[offset + 3] = 255
                }
                continue
            }
            var rgb = (0..<3).map { min(1, Double(pixels[offset + $0]) / (255 * oldAlpha)) }
            var coverage = 1.0
            if let removal {
                let bg = [removal.red, removal.green, removal.blue]
                let distance = zip(rgb, bg).map { abs($0 - $1) }.max() ?? 1
                coverage = high <= low ? (distance > tolerance ? 1 : 0) : min(1, max(0, (distance - low) / (high - low)))
                if coverage > 0 && coverage < 1 {
                    for channel in 0..<3 { rgb[channel] = min(1, max(0, (rgb[channel] - bg[channel] * (1 - coverage)) / coverage)) }
                }
            }
            let alpha = oldAlpha * coverage
            if settings.format == .jpeg {
                let bg = [settings.jpegBackground.red, settings.jpegBackground.green, settings.jpegBackground.blue]
                for channel in 0..<3 { pixels[offset + channel] = UInt8((min(1, max(0, rgb[channel] * alpha + bg[channel] * (1 - alpha))) * 255).rounded()) }
                pixels[offset + 3] = 255
            } else {
                for channel in 0..<3 { pixels[offset + channel] = UInt8((min(1, max(0, rgb[channel] * alpha)) * 255).rounded()) }
                pixels[offset + 3] = UInt8((alpha * 255).rounded())
            }
        }
        guard let output = context.makeImage() else { throw ImageError.cannotRender }
        return output
    }

    private static func encodeWebP(_ image: CGImage, quality: Int, lossless: Bool) throws -> Data {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { throw ImageError.cannotRender }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rgba = UnsafeMutableBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4)
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[index + 3])
            if alpha > 0 && alpha < 255 {
                for c in 0..<3 { rgba[index + c] = UInt8(min(255, Int(rgba[index + c]) * 255 / alpha)) }
            }
        }
        var pointer: UnsafeMutablePointer<UInt8>?
        let size = lossless ? WebPEncodeLosslessRGBA(rgba.baseAddress, Int32(w), Int32(h), Int32(w * 4), &pointer)
                            : WebPEncodeRGBA(rgba.baseAddress, Int32(w), Int32(h), Int32(w * 4), Float(min(100, max(0, quality))), &pointer)
        guard size > 0, let pointer else { throw ImageError.cannotEncode }
        defer { WebPFree(pointer) }
        return Data(bytes: pointer, count: size)
    }

    private static func decodeWebP(_ data: Data) throws -> CGImage {
        var w: Int32 = 0, h: Int32 = 0
        let pointer = data.withUnsafeBytes { WebPDecodeRGBA($0.bindMemory(to: UInt8.self).baseAddress, data.count, &w, &h) }
        guard let pointer, w > 0, h > 0 else { throw ImageError.cannotDecode }
        defer { WebPFree(pointer) }
        return try rgbaImage(pointer: pointer, width: Int(w), height: Int(h))
    }

    static func decodeWebPScaled(_ data: Data, maxDimension: Int) throws -> CGImage {
        var w: Int32 = 0, h: Int32 = 0
        let pointer = data.withUnsafeBytes {
            IFWebPDecodeScaled($0.bindMemory(to: UInt8.self).baseAddress, data.count, Int32(maxDimension), &w, &h)
        }
        guard let pointer, w > 0, h > 0 else { throw ImageError.cannotDecode }
        defer { IFWebPFree(pointer) }
        return try rgbaImage(pointer: pointer, width: Int(w), height: Int(h))
    }

    private static func rgbaImage(pointer: UnsafeMutablePointer<UInt8>, width: Int, height: Int) throws -> CGImage {
        let bytes = Data(bytes: pointer, count: width * height * 4)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ImageError.cannotDecode }
        return image
    }
}
