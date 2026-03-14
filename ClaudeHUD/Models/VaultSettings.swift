import Foundation

struct VaultSettings: Equatable, Identifiable, Codable {
    let id: UUID
    let path: String
    let name: String
    private var _bookmarkData: Data?

    enum CodingKeys: String, CodingKey {
        case id, path, name, _bookmarkData
    }

    init(path: String, name: String) {
        self.id = UUID()
        self.path = path
        self.name = name
    }

    var bookmarkData: Data? {
        get {
            _bookmarkData ?? UserDefaults.standard.data(forKey: "obsidian.vaultBookmark_\(id.uuidString)")
        }
        set {
            _bookmarkData = newValue
            if let data = newValue {
                UserDefaults.standard.set(data, forKey: "obsidian.vaultBookmark_\(id.uuidString)")
            } else {
                UserDefaults.standard.removeObject(forKey: "obsidian.vaultBookmark_\(id.uuidString)")
            }
        }
    }

    static func loadFromDefaults() -> [VaultSettings] {
        guard let data = UserDefaults.standard.data(forKey: "obsidian.savedVaults") else {
            return []
        }
        do {
            return try JSONDecoder().decode([VaultSettings].self, from: data)
        } catch {
            return []
        }
    }

    func saveToDefaults() {
        var vaults = VaultSettings.loadFromDefaults()
        if let index = vaults.firstIndex(where: { $0.id == self.id }) {
            vaults[index] = self
        } else {
            vaults.append(self)
        }
        do {
            let data = try JSONEncoder().encode(vaults)
            UserDefaults.standard.set(data, forKey: "obsidian.savedVaults")
        } catch {}
    }

    static func == (lhs: VaultSettings, rhs: VaultSettings) -> Bool {
        lhs.id == rhs.id
    }
}
