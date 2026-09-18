import SwiftUI
import AppKit

/// Detailbereich: alles, was über ein Gerät bekannt ist – plus die Felder,
/// mit denen der Nutzer es einordnen kann.
struct DeviceDetailView: View {

    let device: Device
    @EnvironmentObject private var scanner: Scanner

    @State private var name = ""
    @State private var note = ""

    var body: some View {
        content(for: device)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .onAppear { load(device) }
            .onChange(of: device.id) { _, _ in load(device) }
    }

    private func load(_ device: Device) {
        name = device.customName ?? ""
        note = device.note
    }

    private func persist() {
        scanner.updateDevice(id: device.id, customName: name.isEmpty ? nil : name, note: note)
    }

    @ViewBuilder
    private func content(for device: Device) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(device)
                ownNotes(device)
                facts(device)
                if !device.openPorts.isEmpty { ports(device) }
                if !device.bonjourTypes.isEmpty { services(device) }
                actions(device)
            }
            .padding(18)
        }
    }

    // MARK: - Abschnitte

    private func header(_ device: Device) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: device.kind.symbol)
                .font(.system(size: 34))
                .foregroundStyle(Color.accentColor)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                Text(device.kind.label).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(device.isOnline ? "Erreichbar" : "Offline",
                          systemImage: device.isOnline ? "checkmark.circle.fill" : "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(device.isOnline ? .green : .secondary)
                    if device.isSelf {
                        badge("Dieser Mac", color: .blue)
                    } else if device.isGateway {
                        badge("Router", color: .blue)
                    }
                }
            }
            Spacer()
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private func ownNotes(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Eigene Angaben")
            TextField("Eigener Name", text: $name, prompt: Text("z. B. „Drucker Arbeitszimmer“"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(persist)
            TextField("Notiz", text: $note, prompt: Text("Notiz"), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                .onSubmit(persist)
            if device.isAnonymous && !device.isGateway && !device.isSelf {
                Text("Dieses Gerät verrät keinen Namen. Prüfe Hersteller und offene Dienste – "
                     + "oder schalte es testweise ab und scanne erneut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func facts(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Netzwerk")
            fact("IP-Adresse", device.ipString, monospaced: true)
            if let mac = device.mac {
                fact("MAC-Adresse", mac, monospaced: true)
                if device.hasRandomMAC {
                    Text("Zufällige (private) MAC-Adresse – das Gerät verschleiert seine Identität. "
                         + "Bei iPhones und Androids ist das der Normalfall.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                fact("MAC-Adresse", "nicht verfügbar")
            }
            if let identifier = device.bonjourIdentifier, identifier != device.mac {
                fact("Bonjour-Kennung", identifier, monospaced: true)
                Text("Wechselnde Kennung aus dem Bonjour-Eintrag – sie ändert sich regelmäßig "
                     + "und eignet sich nicht zum Wiedererkennen des Geräts.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let vendor = device.vendor { fact("Hersteller", vendor) }
            if let manufacturer = device.manufacturer, manufacturer != device.vendor {
                fact("Hersteller (UPnP)", manufacturer)
            }
            if let model = device.model { fact("Modell", model) }
            if let hostname = device.hostname { fact("DNS-Name", hostname) }
            if let bonjour = device.bonjourName { fact("Bonjour-Name", bonjour) }
            if let netbios = device.netbiosName { fact("NetBIOS-Name", netbios) }
            if let web = device.webName { fact("Weboberfläche", web) }
            if let server = device.webServer { fact("Webserver", server) }
            if let family = device.osFamily, let ttl = device.ttl {
                fact("Betriebssystem", family.label)
                Text("Geschätzt aus dem TTL-Startwert der Ping-Antwort (\(ttl)). "
                     + "Ein Anhaltspunkt, keine Gewissheit – der Wert lässt sich ändern.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rtt = device.rtt { fact("Antwortzeit", String(format: "%.1f ms", rtt * 1000)) }
            fact("Zuerst gesehen", device.firstSeen.germanDateTime)
            fact("Zuletzt gesehen", device.lastSeen.germanDateTime)
        }
    }

    private func ports(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Offene Dienste")
            FlowLayout(spacing: 6) {
                ForEach(device.openPorts, id: \.self) { port in
                    let service = PortScanner.service(for: port)
                    Text(service.map { "\(port) · \($0)" } ?? "\(port)")
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    private func services(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Bonjour-Dienste")
            ForEach(device.bonjourTypes, id: \.self) { type in
                Text(type).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private func actions(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Aktionen")
            HStack {
                if device.openPorts.contains(80) || device.openPorts.contains(443)
                    || device.openPorts.contains(8080) || device.isGateway {
                    Button("Im Browser öffnen") {
                        let scheme = device.openPorts.contains(443) ? "https" : "http"
                        if let url = URL(string: "\(scheme)://\(device.ipString)") { NSWorkspace.shared.open(url) }
                    }
                }
                Button("IP kopieren") { copy(device.ipString) }
                if let mac = device.mac {
                    Button("MAC kopieren") { copy(mac) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }

    private func fact(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Einfaches Fließlayout für die Port-Chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
