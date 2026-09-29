import Foundation

enum ResizeMode: String, Codable, CaseIterable, Identifiable {
    case fit = "Fit", fill = "Fill", exact = "Exact"
    var id: String { rawValue }
}

enum OutputFormat: String, Codable, CaseIterable, Identifiable {
    case webp = "WebP", png = "PNG", jpeg = "JPEG"
    var id: String { rawValue }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue.lowercased() }
}

enum CompressionMode: String, Codable, CaseIterable, Identifiable {
    case manual = "Manual Quality", automatic = "Reduce File Size", maximumSize = "Maximum File Size"
    var id: String { rawValue }
}

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case keep = "Keep Background", white = "Remove White", black = "Remove Black", custom = "Remove Custom Color"
    var id: String { rawValue }
}

enum DestinationMode: String, Codable, CaseIterable, Identifiable {
    case sameFolder = "Same Folder", chosenFolder = "Chosen Folder"
    var id: String { rawValue }
}

enum CollisionPolicy: String, Codable, CaseIterable, Identifiable {
    case rename = "Rename Automatically", ask = "Ask", overwrite = "Overwrite"
    var id: String { rawValue }
}

struct RGBColor: Codable, Equatable, Sendable {
    var red: Double = 1
    var green: Double = 1
    var blue: Double = 1
}

struct ProcessingSettings: Codable, Equatable, Sendable {
    var width: Int? = nil
    var height: Int? = nil
    var resizeMode: ResizeMode = .fit
    var keepAspectRatio = true
    var dontUpscale = true
    var format: OutputFormat = .webp
    var quality = 85
    var webpLossless = false
    var compressionMode: CompressionMode = .manual
    /// Desired reduction relative to the imported file, without changing pixel dimensions.
    var targetReductionPercent = 30
    /// Per-image maximum in KiB, used only in maximumSize mode.
    var maximumSizeKiB = 500
    /// The lowest quality automatic JPEG/WebP compression may use.
    var minimumQuality = 75
    var backgroundMode: BackgroundMode = .keep
    var customColor = RGBColor()
    /// Maximum sRGB channel distance, on a 0...100 scale.
    var tolerance = 10.0
    /// Width of the partial-alpha transition, on the same scale as tolerance.
    var edgeSoftness = 8.0
    var jpegBackground = RGBColor()
    var stripMetadata = true
    var destination: DestinationMode = .sameFolder
    var outputFolderPath: String? = nil
    var prefix = ""
    var suffix = "_optimized"
    var collisionPolicy: CollisionPolicy = .rename

    init() {}

    private enum CodingKeys: String, CodingKey {
        case width, height, resizeMode, keepAspectRatio, dontUpscale, format, quality, webpLossless
        case compressionMode, targetReductionPercent, maximumSizeKiB, minimumQuality
        case backgroundMode, customColor, tolerance, edgeSoftness, jpegBackground, stripMetadata
        case destination, outputFolderPath, prefix, suffix, collisionPolicy
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decodeIfPresent(Int.self, forKey: .width)
        height = try values.decodeIfPresent(Int.self, forKey: .height)
        resizeMode = try values.decodeIfPresent(ResizeMode.self, forKey: .resizeMode) ?? .fit
        keepAspectRatio = try values.decodeIfPresent(Bool.self, forKey: .keepAspectRatio) ?? true
        dontUpscale = try values.decodeIfPresent(Bool.self, forKey: .dontUpscale) ?? true
        format = try values.decodeIfPresent(OutputFormat.self, forKey: .format) ?? .webp
        quality = try values.decodeIfPresent(Int.self, forKey: .quality) ?? 85
        webpLossless = try values.decodeIfPresent(Bool.self, forKey: .webpLossless) ?? false
        compressionMode = try values.decodeIfPresent(CompressionMode.self, forKey: .compressionMode) ?? .manual
        targetReductionPercent = try values.decodeIfPresent(Int.self, forKey: .targetReductionPercent) ?? 30
        maximumSizeKiB = try values.decodeIfPresent(Int.self, forKey: .maximumSizeKiB) ?? 500
        minimumQuality = try values.decodeIfPresent(Int.self, forKey: .minimumQuality) ?? 75
        backgroundMode = try values.decodeIfPresent(BackgroundMode.self, forKey: .backgroundMode) ?? .keep
        customColor = try values.decodeIfPresent(RGBColor.self, forKey: .customColor) ?? RGBColor()
        tolerance = try values.decodeIfPresent(Double.self, forKey: .tolerance) ?? 10
        edgeSoftness = try values.decodeIfPresent(Double.self, forKey: .edgeSoftness) ?? 8
        jpegBackground = try values.decodeIfPresent(RGBColor.self, forKey: .jpegBackground) ?? RGBColor()
        stripMetadata = try values.decodeIfPresent(Bool.self, forKey: .stripMetadata) ?? true
        destination = try values.decodeIfPresent(DestinationMode.self, forKey: .destination) ?? .sameFolder
        outputFolderPath = try values.decodeIfPresent(String.self, forKey: .outputFolderPath)
        prefix = try values.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        suffix = try values.decodeIfPresent(String.self, forKey: .suffix) ?? "_optimized"
        collisionPolicy = try values.decodeIfPresent(CollisionPolicy.self, forKey: .collisionPolicy) ?? .rename
    }

    var removalColor: RGBColor? {
        switch backgroundMode {
        case .keep: nil
        case .white: RGBColor()
        case .black: RGBColor(red: 0, green: 0, blue: 0)
        case .custom: customColor
        }
    }
}

struct ResizePlan: Equatable {
    let width: Int
    let height: Int
    let drawWidth: Double
    let drawHeight: Double

    static func make(sourceWidth: Int, sourceHeight: Int, settings: ProcessingSettings) -> ResizePlan {
        let sw = Double(sourceWidth), sh = Double(sourceHeight)
        let targetW = Double(settings.width ?? sourceWidth)
        let targetH = Double(settings.height ?? sourceHeight)
        let both = settings.width != nil && settings.height != nil
        let effectiveMode: ResizeMode = both ? settings.resizeMode : .fit

        if effectiveMode == .exact && !settings.keepAspectRatio {
            let w = settings.dontUpscale ? min(targetW, sw) : targetW
            let h = settings.dontUpscale ? min(targetH, sh) : targetH
            return ResizePlan(width: max(1, Int(w.rounded())), height: max(1, Int(h.rounded())), drawWidth: w, drawHeight: h)
        }

        let scale: Double
        if settings.width == nil && settings.height == nil {
            scale = 1
        } else if settings.width == nil {
            scale = targetH / sh
        } else if settings.height == nil {
            scale = targetW / sw
        } else if effectiveMode == .fill {
            scale = max(targetW / sw, targetH / sh)
        } else {
            scale = min(targetW / sw, targetH / sh)
        }
        let actualScale = settings.dontUpscale ? min(1, scale) : scale
        let drawW = max(1, sw * actualScale), drawH = max(1, sh * actualScale)
        if effectiveMode == .fill && both && actualScale > 0 && (!settings.dontUpscale || scale <= 1) {
            return ResizePlan(width: max(1, Int(targetW.rounded())), height: max(1, Int(targetH.rounded())), drawWidth: drawW, drawHeight: drawH)
        }
        return ResizePlan(width: max(1, Int(drawW.rounded())), height: max(1, Int(drawH.rounded())), drawWidth: drawW, drawHeight: drawH)
    }
}
