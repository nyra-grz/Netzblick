import Foundation

/// Dauerhaft gemerkte Angaben zu einem Gerät – alles, was ein Scan nicht
/// selbst herausfinden kann.
struct StoredDevice: Codable {
    var id: String
    var firstSeen: Date
    var lastSeen: Date
    var customName: String?
    var note: String
    var lastKnownName: String?
    var lastIP: String?
    var vendor: String?
}

/// Legt die Gerätehistorie in der Library des Nutzers ab.
final class DeviceStore {

    private(set) var entries: [String: StoredDevice] = [:]
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let folder = base.appendingPathComponent("Netzblick", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("devices.json")
        load()
    }

    var storageDescription: String { fileURL.path }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        // Muss zur Schreibstrategie in save() passen – sonst scheitert das
        // Laden stillschweigend und die ganze Historie wäre bei jedem Start weg.
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([String: StoredDevice].self, from: data) else { return }
        entries = decoded
        prune()
    }

    /// Geräte, die seit 90 Tagen nicht mehr aufgetaucht sind, fliegen raus –
    /// sonst wächst die Datei durch wechselnde Zufalls-MACs immer weiter.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        let before = entries.count
        entries = entries.filter {
            $0.value.lastSeen > cutoff || $0.value.customName != nil || !$0.value.note.isEmpty
        }
        if entries.count != before { save() }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func known(_ id: String) -> StoredDevice? { entries[id] }

    /// Übernimmt gespeicherte Angaben in ein frisch gescanntes Gerät.
    func apply(to device: inout Device) {
        guard let stored = entries[device.storageKey] else {
            device.firstSeen = Date()
            return
        }
        device.firstSeen = stored.firstSeen
        device.customName = stored.customName
        device.note = stored.note
    }

    func record(_ devices: [Device]) {
        for device in devices {
            entries[device.storageKey] = StoredDevice(
                id: device.storageKey,
                firstSeen: device.firstSeen,
                lastSeen: device.lastSeen,
                customName: device.customName,
                note: device.note,
                lastKnownName: device.displayName,
                lastIP: device.ipString,
                vendor: device.vendor
            )
        }
        save()
    }

}
