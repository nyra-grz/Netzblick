import Foundation

/// Nachschlagewerk für MAC-Präfixe auf Basis der offiziellen IEEE-Register
/// (MA-L, MA-M und MA-S). Die Tabelle liegt als TSV im App-Bundle.
final class VendorDatabase {

    static let shared = VendorDatabase()

    private var entries: [String: String] = [:]
    private(set) var isLoaded = false

    private init() { load() }

    private func load() {
        guard let url = Self.locateTable(),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        var table: [String: String] = [:]
        table.reserveCapacity(56_000)
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            table[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        entries = table
        isLoaded = !table.isEmpty
    }

    /// Sucht die Tabelle im App-Bundle und – für Tests – neben der Binärdatei.
    private static func locateTable() -> URL? {
        if let url = Bundle.main.url(forResource: "oui", withExtension: "tsv") { return url }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        for candidate in [executable.appendingPathComponent("oui.tsv"),
                          executable.appendingPathComponent("../Resources/oui.tsv")] {
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Hersteller zu einer MAC-Adresse. Berücksichtigt auch die kleineren
    /// IEEE-Blöcke, bei denen sich mehrere Firmen ein 24-Bit-Präfix teilen.
    func vendor(for mac: String) -> String? {
        let hex = mac.uppercased().filter { $0.isHexDigit }
        guard hex.count >= 6 else { return nil }
        let characters = Array(hex)
        for length in [9, 7, 6] where characters.count >= length {
            if let match = entries[String(characters[0..<length])] { return match }
        }
        return nil
    }

    /// Zufällig gewürfelte MAC („private WLAN-Adresse“). Erkennbar am
    /// gesetzten U/L-Bit im ersten Oktett.
    static func isRandomized(_ mac: String) -> Bool {
        let hex = mac.filter { $0.isHexDigit }
        guard hex.count >= 2, let first = UInt8(hex.prefix(2), radix: 16) else { return false }
        return first & 0x02 != 0
    }
}
