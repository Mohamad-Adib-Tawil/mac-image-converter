import Foundation

struct UserPreset: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var settings: ProcessingSettings
}

@MainActor
final class PresetStore: ObservableObject {
    @Published private(set) var userPresets: [UserPreset] = []
    private let key = "ImageForge.UserPresets.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([UserPreset].self, from: data) {
            userPresets = decoded
        }
    }

    func save(name: String, settings: ProcessingSettings) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        userPresets.append(UserPreset(name: trimmed, settings: settings))
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = userPresets.firstIndex(where: { $0.id == id }) else { return }
        userPresets[index].name = trimmed
        persist()
    }

    func delete(_ id: UUID) {
        userPresets.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(userPresets) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func builtIn(_ name: String) -> ProcessingSettings? {
        var settings = ProcessingSettings()
        switch name {
        case "Flutter Asset": settings.format = .png; settings.webpLossless = false; settings.suffix = ""
        case "Website": settings.format = .webp; settings.quality = 82
        case "Transparent Asset": settings.format = .png; settings.backgroundMode = .white; settings.suffix = "_transparent"
        default: return nil
        }
        return settings
    }
}
