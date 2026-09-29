import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.displayScale) private var displayScale
    @EnvironmentObject private var model: WorkspaceModel
    @EnvironmentObject private var presets: PresetStore
    @State private var isDropTarget = false
    @State private var showingSavePreset = false
    @State private var showingManagePresets = false
    @State private var presetName = ""

    private var maximumSizeIsValid: Bool {
        model.settings.compressionMode != .maximumSize || (1...1_048_576).contains(model.settings.maximumSizeKiB)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.tint)
                Text("Mac Image Converter").font(.title2.bold())
                Spacer()
                presetMenu
                Button("Manage Presets…") { showingManagePresets = true }
            }
            .padding(.horizontal, 20).padding(.vertical, 13)

            Divider()

            HSplitView {
                libraryPanel.frame(minWidth: 290, idealWidth: 350, maxWidth: 460)
                VStack(spacing: 0) {
                    previewPanel.frame(minHeight: 250, idealHeight: 320)
                    Divider()
                    settingsPanel
                }
                .frame(minWidth: 690)
            }

            Divider()
            bottomBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Import Issues", isPresented: Binding(get: { !model.importFailures.isEmpty }, set: { if !$0 { model.importFailures = [] } })) {
            Button("OK") { model.importFailures = [] }
        } message: {
            Text(model.importFailures.map { "\($0.filename): \($0.reason)" }.joined(separator: "\n"))
        }
        .sheet(isPresented: $showingSavePreset) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Save Current Settings as Preset").font(.headline)
                TextField("Preset name", text: $presetName)
                HStack {
                    Spacer()
                    Button("Cancel") { showingSavePreset = false }
                    Button("Save") { presets.save(name: presetName, settings: model.settings); showingSavePreset = false }
                        .keyboardShortcut(.defaultAction)
                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(22).frame(width: 370)
        }
        .sheet(isPresented: $showingManagePresets) { PresetManagerView().environmentObject(presets) }
        .sheet(isPresented: $model.showResults) { resultsSheet }
        .sheet(isPresented: $model.showComparison) { fullComparisonSheet }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(["Flutter Asset", "Website", "Transparent Asset"], id: \.self) { name in
                Button(name) { if let preset = PresetStore.builtIn(name) { model.settings = preset } }
            }
            if !presets.userPresets.isEmpty {
                Divider()
                ForEach(presets.userPresets) { preset in Button(preset.name) { model.settings = preset.settings } }
            }
            Divider()
            Button("Save Current Settings as Preset…") { presetName = ""; showingSavePreset = true }
        } label: { Label("Presets", systemImage: "slider.horizontal.3") }
    }

    private var libraryPanel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 28)).foregroundStyle(.tint)
                Text("Drag Images Here").font(.headline)
                Text("PNG, JPEG, and WebP").font(.caption).foregroundStyle(.secondary)
                Button("Choose Images…") { model.chooseImages() }
                if model.isImporting { ProgressView().controlSize(.small) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 175)
            .background(RoundedRectangle(cornerRadius: 12).fill(isDropTarget ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isDropTarget ? Color.accentColor : .clear, lineWidth: 2))
            .padding(14)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        if let url { DispatchQueue.main.async { model.importURLs([url]) } }
                    }
                }
                return !providers.isEmpty
            }

            HStack {
                Text("Selected Images").font(.headline)
                Text("\(model.assets.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { model.clear() }.disabled(model.assets.isEmpty)
            }.padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            if model.assets.isEmpty {
                ContentUnavailableView("No Images Selected", systemImage: "photo.on.rectangle", description: Text("Add images to preview and convert them."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedURL) {
                    ForEach(model.assets) { asset in
                        HStack(spacing: 10) {
                            Image(nsImage: asset.thumbnail).resizable().scaledToFit().frame(width: 46, height: 46)
                                .background(Color(nsColor: .controlBackgroundColor))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(asset.name).lineLimit(1).fontWeight(.medium)
                                Text("\(asset.dimensions) · \(asset.format) · \(asset.fileSize)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Button { model.remove(asset.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Remove \(asset.name)")
                                .accessibilityLabel("Remove \(asset.name)")
                        }
                        .tag(asset.id)
                        .padding(.vertical, 3)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preview").font(.headline)
                Spacer()
                if model.isPreviewing { ProgressView().controlSize(.small) }
                Button("Compare at 100%…") { model.requestFullComparison() }
                    .disabled(model.selectedURL == nil || !maximumSizeIsValid)
                Text("Screen-sized preview · export uses full resolution").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                previewTile(title: "Original", image: model.originalPreview)
                previewTile(title: "Processed", image: model.preview)
            }
            if let error = model.previewError { Text(error).foregroundStyle(.red).font(.caption) }
        }.padding(16)
    }

    private var fullComparisonSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Before and After · 100% Pixels").font(.title2.bold())
                Spacer()
                Button("Close") { model.showComparison = false }
            }
            if model.isComparing {
                ProgressView("Processing full-resolution image…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let comparison = model.comparison {
                Text("Estimated output: \(ByteCountFormatter.string(fromByteCount: comparison.outputBytes, countStyle: .file)) · Preview uses the same full-resolution encoding as export.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    comparisonTile("Original", image: comparison.original, size: comparison.originalSize)
                    comparisonTile("Processed", image: comparison.processed, size: comparison.processedSize)
                }
            } else {
                VStack(spacing: 12) {
                    Text(model.comparisonError ?? "The comparison needs to be refreshed.")
                        .foregroundStyle(model.comparisonError == nil ? Color.secondary : Color.red)
                    Button("Refresh Comparison") { model.requestFullComparison() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 570, idealHeight: 680)
    }

    private func comparisonTile(_ title: String, image: NSImage, size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) · \(Int(size.width)) × \(Int(size.height)) px").font(.caption)
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: size.width / displayScale, height: size.height / displayScale)
                    .background(Checkerboard())
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewTile(title: String, image: NSImage?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                Checkerboard()
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(8) }
                else if model.selectedURL == nil { Text("Select an image").foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Processing Settings").font(.headline)
                GroupBox("Size") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            dimensionField("Width", value: $model.settings.width)
                            dimensionField("Height", value: $model.settings.height)
                            Picker("Mode", selection: $model.settings.resizeMode) {
                                ForEach(ResizeMode.allCases) { Text($0.rawValue).tag($0) }
                            }.frame(width: 155)
                        }
                        HStack {
                            Toggle("Keep Aspect Ratio", isOn: $model.settings.keepAspectRatio)
                            Toggle("Don’t Upscale", isOn: $model.settings.dontUpscale)
                        }
                        Text("Fit preserves the entire image; Fill center-crops; Exact stretches when aspect ratio is off. One Auto dimension preserves proportion. Don’t Upscale limits enlargement.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                GroupBox("Format") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Output", selection: $model.settings.format) {
                                ForEach(OutputFormat.allCases) { Text($0.rawValue).tag($0) }
                            }.frame(width: 210)
                        }
                        if model.settings.format == .webp { Toggle("Lossless WebP", isOn: $model.settings.webpLossless) }
                        if model.settings.format == .jpeg { colorControl("JPEG Background", color: $model.settings.jpegBackground) }
                    }.padding(6)
                }
                GroupBox("Compression") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Mode", selection: $model.settings.compressionMode) {
                            ForEach(CompressionMode.allCases) { Text($0.rawValue).tag($0) }
                        }.frame(width: 280)
                        if model.settings.format == .png {
                            Text(model.settings.compressionMode == .automatic
                                 ? "Tests several lossless PNG filters and keeps the smallest file. Pixel dimensions and colors stay unchanged."
                                 : model.settings.compressionMode == .maximumSize
                                 ? "Uses lossless PNG filters. Files that cannot meet the limit are reported as failures."
                                 : "PNG uses lossless compression; quality is always preserved.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if model.settings.format == .webp && model.settings.webpLossless {
                            Text(model.settings.compressionMode == .maximumSize
                                 ? "Lossless WebP preserves pixels. Files that cannot meet the limit are reported as failures."
                                 : "Lossless WebP preserves image pixels. Quality targets apply only to lossy WebP and JPEG.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if model.settings.compressionMode == .maximumSize {
                            HStack {
                                Text("Maximum per image")
                                TextField("KB", value: $model.settings.maximumSizeKiB, format: .number)
                                    .frame(width: 95)
                                Text("KB").foregroundStyle(.secondary)
                            }
                            Text("Uses the highest tested JPEG/WebP quality that fits. If the limit cannot be met, the image is skipped and reported. 1–1,048,576 KB.")
                                .font(.caption).foregroundStyle(.secondary)
                            if !maximumSizeIsValid {
                                Text("Enter a maximum between 1 and 1,048,576 KB.")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        if (model.settings.format == .jpeg || (model.settings.format == .webp && !model.settings.webpLossless))
                            && model.settings.compressionMode != .manual {
                            if model.settings.compressionMode == .automatic {
                            HStack {
                                Text("Target reduction")
                                Slider(value: reductionBinding, in: 10...80, step: 5)
                                Text("\(model.settings.targetReductionPercent)%").monospacedDigit().frame(width: 43)
                            }
                            }
                            HStack {
                                Text("Minimum quality")
                                Slider(value: minimumQualityBinding, in: 50...95, step: 5)
                                Text("\(model.settings.minimumQuality)").monospacedDigit().frame(width: 43)
                            }
                            Text(model.settings.compressionMode == .automatic
                                 ? "Searches for high quality while aiming for the target size. The target is best effort; pixel dimensions stay unchanged unless Size settings request resizing."
                                 : "Pixel dimensions stay unchanged unless Size settings request resizing.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if model.settings.compressionMode == .manual && model.settings.format != .png {
                            HStack {
                                Text("Quality")
                                Slider(value: qualityBinding, in: 0...100)
                                Text("\(model.settings.quality)").monospacedDigit().frame(width: 43)
                            }
                        }
                    }.padding(6)
                }
                GroupBox("Background Removal") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Mode", selection: $model.settings.backgroundMode) {
                            ForEach(BackgroundMode.allCases) { Text($0.rawValue).tag($0) }
                        }.frame(width: 270)
                        if model.settings.backgroundMode == .custom { colorControl("Remove Color", color: $model.settings.customColor) }
                        if model.settings.backgroundMode != .keep {
                            HStack { Text("Tolerance"); Slider(value: $model.settings.tolerance, in: 0...100); Text("\(Int(model.settings.tolerance))").monospacedDigit().frame(width: 28) }
                            HStack { Text("Edge Softness"); Slider(value: $model.settings.edgeSoftness, in: 0...100); Text("\(Int(model.settings.edgeSoftness))").monospacedDigit().frame(width: 28) }
                            Text("Tolerance is the maximum RGB channel distance from the chosen color. Softness blends partial alpha around that threshold.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(6)
                }
                GroupBox("Output") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Picker("Destination", selection: $model.settings.destination) {
                                ForEach(DestinationMode.allCases) { Text($0.rawValue).tag($0) }
                            }.frame(width: 245)
                            if model.settings.destination == .chosenFolder { Button("Choose Folder…") { model.chooseOutputFolder() } }
                        }
                        if model.settings.destination == .chosenFolder { Text(model.settings.outputFolderPath ?? "No folder chosen").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        HStack {
                            TextField("Prefix", text: $model.settings.prefix)
                            TextField("Suffix", text: $model.settings.suffix)
                        }
                        Picker("Existing Files", selection: $model.settings.collisionPolicy) {
                            ForEach(CollisionPolicy.allCases) { Text($0.rawValue).tag($0) }
                        }.frame(width: 290)
                        Toggle("Strip Metadata", isOn: $model.settings.stripMetadata)
                    }.padding(6)
                }
            }.padding(16)
        }
    }

    private func dimensionField(_ title: String, value: Binding<Int?>) -> some View {
        TextField(title + " (Auto)", text: Binding(
            get: { value.wrappedValue.map(String.init) ?? "" },
            set: { text in if text.isEmpty { value.wrappedValue = nil } else if let number = Int(text), number > 0 { value.wrappedValue = number } }
        )).frame(width: 122).accessibilityLabel(title + " in pixels, blank for Auto")
    }

    private var qualityBinding: Binding<Double> {
        Binding(get: { Double(model.settings.quality) }, set: { model.settings.quality = Int($0.rounded()) })
    }

    private var reductionBinding: Binding<Double> {
        Binding(get: { Double(model.settings.targetReductionPercent) },
                set: { model.settings.targetReductionPercent = Int($0.rounded()) })
    }

    private var minimumQualityBinding: Binding<Double> {
        Binding(get: { Double(model.settings.minimumQuality) },
                set: { model.settings.minimumQuality = Int($0.rounded()) })
    }

    private func colorControl(_ title: String, color: Binding<RGBColor>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(.sRGB, red: color.wrappedValue.red, green: color.wrappedValue.green, blue: color.wrappedValue.blue, opacity: 1) },
            set: { selected in
                let ns = NSColor(selected).usingColorSpace(.sRGB) ?? .white
                color.wrappedValue = RGBColor(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
            }
        ), supportsOpacity: false)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if model.isConverting {
                ProgressView(value: Double(model.completed), total: Double(max(model.batchTotal, 1))).frame(width: 170)
                Text("\(model.completed) / \(model.batchTotal) · \(model.currentFile)").lineLimit(1).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancel() }
            } else {
                Text(model.assets.isEmpty ? "Add images to begin" : "\(model.assets.count) image\(model.assets.count == 1 ? "" : "s") ready")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Convert \(model.assets.count) Image\(model.assets.count == 1 ? "" : "s")") { model.convert() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.assets.isEmpty || !maximumSizeIsValid || (model.settings.destination == .chosenFolder && model.settings.outputFolderPath == nil))
            }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private var resultsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.wasCancelled ? "Conversion Cancelled" : "Conversion Complete").font(.title2.bold())
            Text("\(model.successes) converted · \(model.failures.count) failed")
            if model.successes > 0 {
                let input = ByteCountFormatter.string(fromByteCount: model.inputBytes, countStyle: .file)
                let output = ByteCountFormatter.string(fromByteCount: model.outputBytes, countStyle: .file)
                let reduction = model.inputBytes > 0
                    ? Int((1 - Double(model.outputBytes) / Double(model.inputBytes)) * 100)
                    : 0
                Text("\(input) → \(output) · \(reduction >= 0 ? "\(reduction)% smaller" : "\(-reduction)% larger")")
                    .foregroundStyle(.secondary)
            }
            if !model.failures.isEmpty {
                List(model.failures) { failure in
                    VStack(alignment: .leading) {
                        Text(failure.filename).fontWeight(.medium)
                        Text(failure.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(height: 180)
            }
            HStack { Spacer(); Button("Done") { model.showResults = false }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 470)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(nsColor: .controlBackgroundColor)))
            let tile: CGFloat = 12
            for row in 0...Int(size.height / tile) {
                for column in 0...Int(size.width / tile) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)), with: .color(.gray.opacity(0.16)))
                }
            }
        }
    }
}

private struct PresetManagerView: View {
    @EnvironmentObject private var presets: PresetStore
    @Environment(\.dismiss) private var dismiss
    @State private var editedNames: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manage Presets").font(.title2.bold())
            if presets.userPresets.isEmpty { Text("No saved presets yet.").foregroundStyle(.secondary) }
            ForEach(presets.userPresets) { preset in
                HStack {
                    TextField("Name", text: Binding(get: { editedNames[preset.id] ?? preset.name }, set: { editedNames[preset.id] = $0 }))
                    Button("Rename") { presets.rename(preset.id, to: editedNames[preset.id] ?? preset.name) }
                    Button(role: .destructive) { presets.delete(preset.id) } label: { Image(systemName: "trash") }
                        .help("Delete \(preset.name)")
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(22).frame(width: 480)
    }
}

extension WorkspaceModel {
    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { importURLs(panel.urls) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { settings.outputFolderPath = panel.url?.path }
    }
}
