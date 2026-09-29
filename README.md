# Mac Image Converter

Mac Image Converter is a native SwiftUI macOS utility for batch resizing, file-size reduction, color-based background removal, and PNG, JPEG, or WebP export. Images are imported separately from settings; conversion starts only when **Convert** is pressed and uses a snapshot of the settings at that moment.

## Requirements and build

- macOS 14 or later
- Xcode 27 or a compatible Xcode with the macOS SDK and Swift 5 language mode
- Apple Silicon or Intel Mac

Open `Mac Image Converter.xcodeproj` in Xcode and run the **MacImageConverter** scheme. From Terminal:

```sh
xcodebuild -project 'Mac Image Converter.xcodeproj' -scheme MacImageConverter -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project 'Mac Image Converter.xcodeproj' -scheme MacImageConverter -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

The app has no runtime dependency on Homebrew, ImageMagick, Python, Node.js, or a web service. To regenerate the checked-in Xcode project after adding source files, run `ruby Scripts/generate_project.rb` on a development Mac with the `xcodeproj` Ruby gem. Regeneration is not needed to build the project.

## Architecture

- `MacImageConverter/Views`: native desktop UI, drop target, settings, comparison preview, and preset management.
- `MacImageConverter/State`: workspace state, asynchronous import and batch processing, and UserDefaults-backed presets.
- `MacImageConverter/Models`: settings, image metadata, and resize geometry.
- `MacImageConverter/Processing`: ImageIO/Core Graphics/Core Image processing, output naming, and WebP bridge.
- `Vendor/libwebp`: libwebp 1.5.0 source, compiled into a static library by the Xcode project. It is linked into Mac Image Converter and is not invoked as a command-line program. See the vendor `COPYING` file.

Import supports PNG, JPEG, and WebP. ImageIO handles formats it can decode; a bundled libwebp decoder is used as a WebP fallback. Output supports PNG, JPEG, and WebP, including lossy and lossless WebP. PNG and WebP preserve alpha. JPEG flattens transparency against the selected color.

## Reducing file size

In **Compression**, choose **Reduce File Size** and set a target reduction plus a minimum quality. For JPEG and lossy WebP, Mac Image Converter encodes at several quality levels and keeps the highest tested quality that meets the target when possible. If the target cannot be reached above the minimum quality, it keeps the smallest candidate. This is a best-effort size target, not a guarantee. The results sheet reports the actual input and output byte totals.

For PNG, Reduce File Size compares several native, lossless PNG filters and keeps the smallest output. Lossless WebP preserves pixels and uses its existing lossless encoder. Compression does not change pixel dimensions; the separate Size controls still apply if you set them. Lossy compression can change pixel colors slightly even though the dimensions stay the same.

Choose **Maximum File Size** to set a per-image limit in KB. JPEG and lossy WebP search for the highest tested quality that fits without going below Minimum Quality. PNG and lossless WebP retain their lossless encoding. If an image cannot meet the limit, conversion reports that image as a failure and does not write it. Use **Compare at 100%** to generate an on-demand, full-resolution before/after view and see the encoded output size before saving. Large images can take longer to prepare; the normal preview remains screen-sized for responsiveness.

## Processing behavior

The export pipeline decodes, normalizes EXIF orientation, resizes or center-crops, removes a selected background color, flattens alpha for JPEG, compresses and encodes, then writes the file atomically. Preview uses the same processing and encoding path on a screen-sized source representation; export recalculates compression at full resolution. Processing runs off the main actor one image at a time to bound memory. Cancel stops between files or between compression attempts, and before writing the current encoded file.

Fit preserves the full image inside a bounding box. Fill center-crops to fill both dimensions. Exact stretches when Keep Aspect Ratio is off; with Keep Aspect Ratio on it behaves as Fit. One Auto dimension always preserves proportion. Don't Upscale limits enlargement, so Fill can result in an output smaller than the requested box when the source is too small.

Background removal compares the maximum absolute difference of sRGB channels to the selected color. Tolerance and Edge Softness are both 0–100 scales. Pixels inside the lower edge of the tolerance band become transparent, pixels outside the upper edge remain opaque, and pixels in between retain partial alpha. Existing alpha is multiplied by the computed coverage. Partially removed edge colors are decontaminated against the selected background color to reduce halos. This is color-based removal, so matching colors inside artwork can also be removed; inspect the preview before a batch.

By default, outputs get an `_optimized` suffix and existing files are renamed automatically. The source file is never overwritten by the default policy. Ask and Overwrite are also available; an output path equal to the source path is always renamed.

## Tests

The XCTest suite uses generated image fixtures and checks resize modes, aspect ratio, no-upscale behavior, background removal, partial alpha, encoded format signatures and dimensions, lossless PNG optimization, automatic JPEG/WebP size reduction, maximum file-size enforcement, filename collision handling, legacy preset decoding, and batch settings snapshots. Run tests with the Xcode command above.

## Known limitations

- WebP encoding through the simple libwebp API does not copy source metadata. PNG and JPEG can preserve source metadata when Strip Metadata is off.
- Cancellation takes effect between files or before a finished file is written. A codec call already in progress cannot be interrupted.
- Preview downsamples large sources for responsiveness; very fine pixel-level effects should be checked on an exported file.
