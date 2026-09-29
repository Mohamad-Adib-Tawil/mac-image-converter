import XCTest
import AppKit
import ImageIO
@testable import MacImageConverter

final class MacImageConverterTests: XCTestCase {
    func testResizeModesAndAspectRatio() {
        var settings = ProcessingSettings()
        settings.width = 200; settings.height = 200; settings.dontUpscale = false
        XCTAssertEqual(ResizePlan.make(sourceWidth: 400, sourceHeight: 200, settings: settings),
                       ResizePlan(width: 200, height: 100, drawWidth: 200, drawHeight: 100))
        settings.resizeMode = .fill
        XCTAssertEqual(ResizePlan.make(sourceWidth: 400, sourceHeight: 200, settings: settings),
                       ResizePlan(width: 200, height: 200, drawWidth: 400, drawHeight: 200))
        settings.resizeMode = .exact; settings.keepAspectRatio = false
        XCTAssertEqual(ResizePlan.make(sourceWidth: 400, sourceHeight: 200, settings: settings).width, 200)
        XCTAssertEqual(ResizePlan.make(sourceWidth: 400, sourceHeight: 200, settings: settings).height, 200)
        settings.keepAspectRatio = true
        XCTAssertEqual(ResizePlan.make(sourceWidth: 400, sourceHeight: 200, settings: settings).height, 100)
        settings.width = nil; settings.height = 100
        XCTAssertEqual(ResizePlan.make(sourceWidth: 400, sourceHeight: 200, settings: settings).width, 200)
        settings.height = nil; settings.width = 800; settings.dontUpscale = true
        XCTAssertEqual(ResizePlan.make(sourceWidth: 400, sourceHeight: 200, settings: settings).width, 400)
    }

    func testBackgroundRemovalAndAlpha() throws {
        let fixture = try makeFixture([(255,255,255,255), (0,0,0,255), (240,240,240,255), (255,0,0,128)])
        var settings = ProcessingSettings()
        settings.format = .png; settings.backgroundMode = .white; settings.tolerance = 3; settings.edgeSoftness = 0
        var pixels = try processedPixels(fixture, settings)
        XCTAssertEqual(pixels[3], 0)
        XCTAssertEqual(pixels[7], 255)
        XCTAssertEqual(pixels[11], 255)
        XCTAssertEqual(pixels[15], 128, accuracy: 2)
        settings.tolerance = 7
        pixels = try processedPixels(fixture, settings)
        XCTAssertEqual(pixels[11], 0)
        settings.backgroundMode = .black; settings.tolerance = 3
        pixels = try processedPixels(fixture, settings)
        XCTAssertEqual(pixels[7], 0)
        settings.backgroundMode = .custom
        settings.customColor = RGBColor(red: 1, green: 0, blue: 0)
        pixels = try processedPixels(fixture, settings)
        XCTAssertEqual(pixels[15], 0)
        settings.backgroundMode = .white; settings.tolerance = 6; settings.edgeSoftness = 8
        pixels = try processedPixels(fixture, settings)
        XCTAssertGreaterThan(pixels[11], 0)
        XCTAssertLessThan(pixels[11], 255)
    }

    func testFormatsAndJPEGFlattening() throws {
        let fixture = try makeFixture([(0,0,0,0), (0,255,0,255)])
        var settings = ProcessingSettings()
        settings.format = .png
        let png = try encoded(fixture, settings)
        XCTAssertTrue(png.starts(with: [137,80,78,71]))
        XCTAssertEqual(try decodedDimensions(png).0, 2)
        settings.format = .webp; settings.webpLossless = true
        let webp = try encoded(fixture, settings)
        XCTAssertEqual(String(data: webp.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(try decodedDimensions(webp).0, 2)
        XCTAssertEqual(try ImageEngine.decodeWebPScaled(webp, maxDimension: 1).width, 1)
        XCTAssertEqual(try pixelBytes(ImageEngine.decodeWebPScaled(webp, maxDimension: 2))[3], 0)
        settings.format = .jpeg; settings.jpegBackground = RGBColor()
        let flattened = try processedPixels(fixture, settings)
        XCTAssertEqual(Array(flattened.prefix(4)), [255, 255, 255, 255])
        let jpeg = try encoded(fixture, settings)
        XCTAssertTrue(jpeg.starts(with: [0xFF, 0xD8]))
        XCTAssertEqual(try decodedDimensions(jpeg).0, 2)
    }

    func testAutomaticCompressionPreservesDimensionsAndReducesBytes() throws {
        let source = try makeNoisyJPEGFixture()
        let sourceSize = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        var settings = ProcessingSettings()
        settings.format = .jpeg
        settings.compressionMode = .automatic
        settings.targetReductionPercent = 30
        settings.minimumQuality = 65
        let image = try ImageEngine.process(source, settings: settings)
        let compressedJPEG = try ImageEngine.encode(image, sourceURL: source, settings: settings)
        XCTAssertEqual(try decodedDimensions(compressedJPEG).0, 384)
        XCTAssertEqual(try decodedDimensions(compressedJPEG).1, 384)
        XCTAssertLessThan(compressedJPEG.count, sourceSize)
        XCTAssertLessThanOrEqual(Double(compressedJPEG.count), Double(sourceSize) * 0.7)
        var maximumQuality = settings
        maximumQuality.compressionMode = .manual
        maximumQuality.quality = 100
        XCTAssertLessThan(compressedJPEG.count, try ImageEngine.encode(image, sourceURL: source, settings: maximumQuality).count)

        settings.format = .webp
        let webpImage = try ImageEngine.process(source, settings: settings)
        let compressedWebP = try ImageEngine.encode(webpImage, sourceURL: source, settings: settings)
        XCTAssertEqual(try ImageEngine.decodeWebPScaled(compressedWebP, maxDimension: 384).width, 384)
        maximumQuality.format = .webp
        XCTAssertLessThanOrEqual(compressedWebP.count, try ImageEngine.encode(webpImage, sourceURL: source, settings: maximumQuality).count)
    }

    func testAutomaticPNGCompressionRemainsLossless() throws {
        let source = try makeFixture([(255,255,255,0), (0,120,200,255), (40,180,90,128)])
        var settings = ProcessingSettings()
        settings.format = .png
        let normal = try encoded(source, settings)
        settings.compressionMode = .automatic
        let optimized = try encoded(source, settings)
        XCTAssertLessThanOrEqual(optimized.count, normal.count)
        XCTAssertEqual(try decodedDimensions(optimized).0, 3)
        let normalImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(normal as CFData, nil)!, 0, nil))
        let optimizedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(optimized as CFData, nil)!, 0, nil))
        XCTAssertEqual(try pixelBytes(normalImage), try pixelBytes(optimizedImage))
    }

    func testMaximumFileSizeIsEnforced() throws {
        let source = try makeNoisyJPEGFixture()
        var settings = ProcessingSettings()
        settings.format = .jpeg
        settings.compressionMode = .maximumSize
        settings.minimumQuality = 50
        let image = try ImageEngine.process(source, settings: settings)
        var floorSettings = settings
        floorSettings.compressionMode = .manual
        floorSettings.quality = 50
        let floorBytes = try ImageEngine.encode(image, sourceURL: source, settings: floorSettings).count
        settings.maximumSizeKiB = Int(ceil(Double(floorBytes) / 1024)) + 1
        let output = try ImageEngine.encode(image, sourceURL: source, settings: settings)
        XCTAssertLessThanOrEqual(output.count, settings.maximumSizeKiB * 1024)
        XCTAssertEqual(try decodedDimensions(output).0, 384)
        settings.maximumSizeKiB = 1
        XCTAssertThrowsError(try ImageEngine.encode(image, sourceURL: source, settings: settings)) { error in
            XCTAssertEqual(error as? ImageError, .sizeLimitUnreachable)
        }
        settings.maximumSizeKiB = 0
        XCTAssertThrowsError(try ImageEngine.encode(image, sourceURL: source, settings: settings)) { error in
            XCTAssertEqual(error as? ImageError, .invalidMaximumSize)
        }
    }

    func testLosslessMaximumReportsUnreachableLimit() throws {
        let source = try makeNoisyJPEGFixture()
        var settings = ProcessingSettings()
        settings.format = .png
        settings.compressionMode = .maximumSize
        settings.maximumSizeKiB = 1
        XCTAssertThrowsError(try encoded(source, settings)) { error in
            XCTAssertEqual(error as? ImageError, .sizeLimitUnreachable)
        }
    }

    func testOlderSavedSettingsGainCompressionDefaults() throws {
        var original = ProcessingSettings()
        original.format = .png
        let encoded = try JSONEncoder().encode(original)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "compressionMode")
        legacy.removeValue(forKey: "targetReductionPercent")
        legacy.removeValue(forKey: "maximumSizeKiB")
        legacy.removeValue(forKey: "minimumQuality")
        let decoded = try JSONDecoder().decode(ProcessingSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.format, .png)
        XCTAssertEqual(decoded.compressionMode, .manual)
        XCTAssertEqual(decoded.targetReductionPercent, 30)
        XCTAssertEqual(decoded.maximumSizeKiB, 500)
        XCTAssertEqual(decoded.minimumQuality, 75)
    }

    func testFilenameCollisionAndSnapshot() {
        var settings = ProcessingSettings()
        let source = URL(fileURLWithPath: "/tmp/banner.png")
        let proposed = OutputNamer.proposedURL(source: source, folder: source.deletingLastPathComponent(), settings: settings)
        XCTAssertEqual(proposed.lastPathComponent, "banner_optimized.webp")
        let result = OutputNamer.availableURL(proposed, source: source, reserved: [], exists: { $0 == proposed })
        XCTAssertEqual(result.lastPathComponent, "banner_optimized-2.webp")
        let snapshot = settings
        settings.quality = 10
        XCTAssertEqual(snapshot.quality, 85)
        settings.prefix = "../"
        XCTAssertEqual(OutputNamer.proposedURL(source: source, folder: source.deletingLastPathComponent(), settings: settings).deletingLastPathComponent(), source.deletingLastPathComponent())
    }

    func testLargeImagePreviewAndExportGeometry() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        let context = CGContext(data: nil, width: 4096, height: 3072, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 4096, height: 3072))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var settings = ProcessingSettings()
        settings.width = 1024
        settings.format = .png
        let preview = try ImageEngine.process(url, settings: settings, previewLimit: 800)
        XCTAssertLessThanOrEqual(preview.width, 800)
        let full = try ImageEngine.process(url, settings: settings)
        XCTAssertEqual(full.width, 1024)
        XCTAssertEqual(full.height, 768)
    }

    @MainActor
    func testBatchConversionUsesSettingsAtStart() async throws {
        let first = try makeFixture([(255,255,255,255), (0,0,255,255)])
        let second = try makeFixture([(0,0,0,255), (255,0,0,255)])
        let model = WorkspaceModel()
        model.importURLs([first, second])
        for _ in 0..<100 where model.assets.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.assets.count, 2)
        XCTAssertEqual(model.assets.first?.format, "PNG")
        model.settings.format = .webp
        model.settings.webpLossless = true
        model.convert()
        model.settings.format = .jpeg
        for _ in 0..<200 where model.isConverting { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(model.isConverting)
        XCTAssertEqual(model.successes, 2)
        XCTAssertEqual(model.completed, 2)
        XCTAssertGreaterThan(model.inputBytes, 0)
        XCTAssertGreaterThan(model.outputBytes, 0)
        XCTAssertTrue(model.failures.isEmpty)
        for source in [first, second] {
            let output = source.deletingPathExtension().appendingPathExtension("webp")
            let optimized = output.deletingLastPathComponent().appendingPathComponent(source.deletingPathExtension().lastPathComponent + "_optimized.webp")
            let data = try Data(contentsOf: optimized)
            XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        }
    }

    @MainActor
    func testUserPresetSaveRenameAndDelete() {
        let store = PresetStore()
        let name = "MacImageConverter Test \(UUID().uuidString)"
        var settings = ProcessingSettings()
        settings.format = .png
        store.save(name: name, settings: settings)
        guard let preset = store.userPresets.first(where: { $0.name == name }) else {
            XCTFail("Saved preset missing")
            return
        }
        XCTAssertEqual(preset.settings.format, .png)
        store.rename(preset.id, to: name + " Renamed")
        XCTAssertEqual(store.userPresets.first(where: { $0.id == preset.id })?.name, name + " Renamed")
        store.delete(preset.id)
        XCTAssertNil(store.userPresets.first(where: { $0.id == preset.id }))
    }

    private func makeFixture(_ pixels: [(UInt8, UInt8, UInt8, UInt8)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        var bytes = pixels.flatMap { [$0.0, $0.1, $0.2, $0.3] }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: pixels.count, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: pixels.count * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func makeNoisyJPEGFixture() throws -> URL {
        let size = 384
        var seed: UInt32 = 0xA15E_4B39
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            for channel in 0..<3 {
                seed = 1_664_525 &* seed &+ 1_013_904_223
                pixels[index + channel] = UInt8(truncatingIfNeeded: seed >> 16)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func processedPixels(_ url: URL, _ settings: ProcessingSettings) throws -> [UInt8] {
        try pixelBytes(ImageEngine.process(url, settings: settings))
    }

    private func pixelBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func encoded(_ url: URL, _ settings: ProcessingSettings) throws -> Data {
        try ImageEngine.encode(ImageEngine.process(url, settings: settings), sourceURL: url, settings: settings)
    }

    private func decodedDimensions(_ data: Data) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageError.cannotDecode }
        return (image.width, image.height)
    }
}
