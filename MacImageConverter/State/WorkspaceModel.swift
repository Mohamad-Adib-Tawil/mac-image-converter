import AppKit
import Combine

struct BatchFailure: Identifiable, Sendable {
    let id = UUID()
    let filename: String
    let reason: String
}

private struct PreviewPair: @unchecked Sendable {
    let original: NSImage
    let processed: NSImage
}

struct FullComparison: @unchecked Sendable {
    let original: NSImage
    let processed: NSImage
    let originalSize: CGSize
    let processedSize: CGSize
    let outputBytes: Int64
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var assets: [ImageAsset] = []
    @Published var settings = ProcessingSettings() { didSet { invalidateComparison(); requestPreview() } }
    @Published var selectedURL: URL? { didSet { invalidateComparison(); requestPreview() } }
    @Published var preview: NSImage?
    @Published var originalPreview: NSImage?
    @Published var previewError: String?
    @Published var isPreviewing = false
    @Published var comparison: FullComparison?
    @Published var comparisonError: String?
    @Published var isComparing = false
    @Published var showComparison = false { didSet { if !showComparison { invalidateComparison() } } }
    @Published var isImporting = false
    @Published var isConverting = false
    @Published var completed = 0
    @Published var batchTotal = 0
    @Published var currentFile = ""
    @Published var successes = 0
    @Published var inputBytes: Int64 = 0
    @Published var outputBytes: Int64 = 0
    @Published var wasCancelled = false
    @Published var failures: [BatchFailure] = []
    @Published var importFailures: [BatchFailure] = []
    @Published var showResults = false

    private var previewTask: Task<Void, Never>?
    private var comparisonTask: Task<Void, Never>?
    private var comparisonGeneration = 0
    private var conversionTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var importGeneration = 0
    private var pendingURLs = Set<URL>()

    func importURLs(_ urls: [URL]) {
        let existing = Set(assets.map(\.id))
        let candidates = Set(urls.map(\.standardizedFileURL))
        let folders = candidates.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? $0.hasDirectoryPath }
        if !folders.isEmpty {
            importFailures.append(contentsOf: folders.map { BatchFailure(filename: $0.lastPathComponent, reason: "Folders cannot be imported. Choose image files instead.") })
        }
        let unique = candidates.subtracting(folders).filter { !existing.contains($0) && !pendingURLs.contains($0) }
        guard !unique.isEmpty else { return }
        pendingURLs.formUnion(unique)
        let generation = importGeneration
        isImporting = true
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let owner = self else { return }
            var imported: [ImageAsset] = []
            var errors: [BatchFailure] = []
            for url in unique {
                autoreleasepool {
                    do { imported.append(try ImageEngine.inspect(url)) }
                    catch { errors.append(BatchFailure(filename: url.lastPathComponent, reason: error.localizedDescription)) }
                }
            }
            await owner.completeImport(imported, errors: errors, urls: unique, generation: generation)
        }
    }

    private func completeImport(_ imported: [ImageAsset], errors: [BatchFailure], urls: Set<URL>, generation: Int) {
        pendingURLs.subtract(urls)
        isImporting = !pendingURLs.isEmpty
        guard generation == importGeneration else { return }
        assets.append(contentsOf: imported)
        importFailures.append(contentsOf: errors)
        if selectedURL == nil { selectedURL = assets.first?.url }
    }

    func remove(_ id: URL) {
        assets.removeAll { $0.id == id }
        if selectedURL == id { selectedURL = assets.first?.url }
    }

    func clear() {
        importGeneration += 1
        assets.removeAll()
        selectedURL = nil
        preview = nil
        originalPreview = nil
        invalidateComparison()
    }

    private func invalidateComparison() {
        comparisonGeneration += 1
        comparisonTask?.cancel()
        comparison = nil
        comparisonError = nil
        isComparing = false
    }

    func requestFullComparison() {
        guard let url = selectedURL else { return }
        invalidateComparison()
        showComparison = true
        isComparing = true
        let generation = comparisonGeneration
        let snapshot = settings
        comparisonTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let owner = self else { return }
            let result: Result<FullComparison, Error>
            do {
                let original = try ImageEngine.process(url, settings: ProcessingSettings())
                try Task.checkCancellation()
                let processed = try ImageEngine.process(url, settings: snapshot)
                let data = try ImageEngine.encode(processed, sourceURL: url, settings: snapshot)
                try Task.checkCancellation()
                let decoded = try ImageEngine.decodeOutput(data, format: snapshot.format)
                result = .success(FullComparison(
                    original: NSImage(cgImage: original, size: NSSize(width: original.width, height: original.height)),
                    processed: NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height)),
                    originalSize: CGSize(width: original.width, height: original.height),
                    processedSize: CGSize(width: decoded.width, height: decoded.height),
                    outputBytes: Int64(data.count)))
            } catch { result = .failure(error) }
            await owner.completeComparison(result, generation: generation)
        }
    }

    private func completeComparison(_ result: Result<FullComparison, Error>, generation: Int) {
        guard generation == comparisonGeneration else { return }
        isComparing = false
        switch result {
        case .success(let value): comparison = value
        case .failure(let error):
            if !(error is CancellationError) { comparisonError = error.localizedDescription }
        }
    }

    func requestPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        previewTask?.cancel()
        preview = nil
        previewError = nil
        guard let url = selectedURL else { isPreviewing = false; return }
        let snapshot = settings
        isPreviewing = true
        previewTask = Task.detached(priority: .utility) { [weak self] in
            guard let owner = self else { return }
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let result: Result<PreviewPair, Error>
            do {
                let originalCG = try ImageEngine.process(url, settings: ProcessingSettings(), previewLimit: 1200)
                let cg = try ImageEngine.preview(url, settings: snapshot, limit: 1200)
                result = .success(PreviewPair(original: NSImage(cgImage: originalCG, size: NSSize(width: originalCG.width, height: originalCG.height)),
                                              processed: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))))
            } catch { result = .failure(error) }
            await owner.completePreview(result, generation: generation)
        }
    }

    private func completePreview(_ result: Result<PreviewPair, Error>, generation: Int) {
        guard generation == previewGeneration else { return }
        isPreviewing = false
        switch result {
        case .success(let pair): originalPreview = pair.original; preview = pair.processed
        case .failure(let error): previewError = error.localizedDescription
        }
    }

    func convert() {
        guard !isConverting, !assets.isEmpty else { return }
        let batch = assets.map { (url: $0.url, byteCount: $0.byteCount) }
        let snapshot = settings // An immutable batch snapshot.
        isConverting = true
        completed = 0; batchTotal = batch.count; successes = 0; failures = []
        inputBytes = 0; outputBytes = 0; wasCancelled = false
        currentFile = ""; showResults = false
        conversionTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let owner = self else { return }
            var reserved = Set<URL>()
            for (source, sourceBytes) in batch {
                if Task.isCancelled { break }
                await owner.setCurrentFile(source.lastPathComponent)
                do {
                    let folder: URL
                    switch snapshot.destination {
                    case .sameFolder: folder = source.deletingLastPathComponent()
                    case .chosenFolder:
                        guard let path = snapshot.outputFolderPath else { throw ImageError.outputUnavailable }
                        folder = URL(fileURLWithPath: path, isDirectory: true)
                    }
                    let proposed = OutputNamer.proposedURL(source: source, folder: folder, settings: snapshot)
                    let target: URL
                    if snapshot.collisionPolicy == .rename || proposed.standardizedFileURL == source.standardizedFileURL || reserved.contains(proposed.standardizedFileURL) {
                        target = OutputNamer.availableURL(proposed, source: source, reserved: reserved, exists: { FileManager.default.fileExists(atPath: $0.path) })
                    } else if snapshot.collisionPolicy == .ask && FileManager.default.fileExists(atPath: proposed.path) {
                        let overwrite = await Self.confirmOverwrite(proposed)
                        target = overwrite ? proposed : OutputNamer.availableURL(proposed, source: source, reserved: reserved, exists: { FileManager.default.fileExists(atPath: $0.path) })
                    } else { target = proposed }
                    let writtenBytes = try autoreleasepool { () throws -> Int64 in
                        let image = try ImageEngine.process(source, settings: snapshot)
                        let data = try ImageEngine.encode(image, sourceURL: source, settings: snapshot)
                        if Task.isCancelled { throw CancellationError() }
                        try data.write(to: target, options: .atomic)
                        return Int64(data.count)
                    }
                    reserved.insert(target.standardizedFileURL)
                    await owner.recordSuccess(inputBytes: sourceBytes, outputBytes: writtenBytes)
                } catch {
                    if Task.isCancelled { break }
                    await owner.recordFailure(filename: source.lastPathComponent, reason: error.localizedDescription)
                }
                await owner.advanceProgress()
            }
            await owner.finishConversion(cancelled: Task.isCancelled)
        }
    }

    func cancel() { conversionTask?.cancel() }

    private func setCurrentFile(_ name: String) { currentFile = name }
    private func recordSuccess(inputBytes: Int64, outputBytes: Int64) {
        successes += 1
        self.inputBytes += inputBytes
        self.outputBytes += outputBytes
    }
    private func recordFailure(filename: String, reason: String) { failures.append(BatchFailure(filename: filename, reason: reason)) }
    private func advanceProgress() { completed += 1 }
    private func finishConversion(cancelled: Bool) {
        isConverting = false
        currentFile = ""
        wasCancelled = cancelled
        showResults = true
        conversionTask = nil
    }

    private static func confirmOverwrite(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Replace \(url.lastPathComponent)?"
        alert.informativeText = "The existing output file will be replaced."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Rename Instead")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
