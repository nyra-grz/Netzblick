import SwiftUI

/// Kopfzeile mit den Eckdaten des gescannten Netzes.
struct NetworkSummaryBar: View {

    @EnvironmentObject private var scanner: Scanner

    private var onlineCount: Int { scanner.devices.filter(\.isOnline).count }
    private var namedCount: Int { scanner.devices.filter { !$0.isAnonymous }.count }

    /// Anteil der Geräte ohne jeden Namen aus einer Netzwerkquelle.
    private var namelessShare: Double {
        guard scanner.devices.count >= 5 else { return 0 }
        return Double(scanner.devices.filter(\.isAnonymous).count) / Double(scanner.devices.count)
    }

    /// macOS gibt Link-Layer-Adressen nur an Apps mit erteilter
    /// Netzwerkberechtigung heraus. Fehlen sie durchgängig, ist das der Grund.
    private var macDataMissing: Bool {
        scanner.devices.count >= 2 && scanner.devices.allSatisfy { $0.mac == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 22) {
                summaryItem(icon: "network", title: "Netzwerk",
                            value: scanner.selectedInterface?.cidr ?? "–",
                            detail: scanner.selectedInterface?.displayName)
                summaryItem(icon: "wifi.router.fill", title: "Router",
                            value: scanner.gateway.map(SystemNet.ipString) ?? "–",
                            detail: nil)
                summaryItem(icon: "laptopcomputer", title: "Dieser Mac",
                            value: scanner.selectedInterface?.ipString ?? "–",
                            detail: nil)
                Divider().frame(height: 30)
                summaryItem(icon: "desktopcomputer.and.arrow.down", title: "Gefunden",
                            value: "\(scanner.devices.count)",
                            detail: "\(onlineCount) erreichbar")
                summaryItem(icon: "tag", title: "Mit Namen",
                            value: "\(namedCount)",
                            detail: nil)
                Spacer()
                if let lastScan = scanner.lastScan {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Letzter Scan").font(.caption2).foregroundStyle(.secondary)
                        Text(lastScan.germanTime)
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if namelessShare > 0.6 && !scanner.isScanning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "questionmark.circle.fill").foregroundStyle(.secondary)
                    Text("Die meisten Geräte geben keinen Namen preis. Typisch für verwaltete Netze "
                         + "(Wohnheim, Mehrparteienhaus): Der Access Point blockiert die Namensdienste "
                         + "zwischen den Clients, und Handys verstecken sich hinter zufälligen MAC-Adressen. "
                         + "Im eigenen Heimnetz hinter einem eigenen Router findet Netzblick deutlich mehr.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            if !scanner.icmpAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Kein Ping möglich – die Erreichbarkeit wurde über TCP-Verbindungstests "
                         + "ermittelt, deshalb fehlen die Antwortzeiten.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            if macDataMissing {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                    Text("macOS gibt MAC-Adressen nur mit erteilter Netzwerkberechtigung heraus. "
                         + "Erlaube Netzblick unter „Systemeinstellungen › Datenschutz & Sicherheit › Lokales Netzwerk“ "
                         + "den Zugriff und starte einen neuen Scan.")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Einstellungen öffnen") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .background(.background.secondary)
    }

    private func summaryItem(icon: String, title: String, value: String,
                             detail: String?) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .fixedSize()
    }
}
