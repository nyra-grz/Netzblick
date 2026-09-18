import SwiftUI
import AppKit

enum DeviceFilter: String, CaseIterable, Identifiable {
    case all = "Alle Geräte"
    case online = "Nur erreichbare"
    case named = "Nur mit Namen"

    var id: String { rawValue }
}

struct ContentView: View {

    @EnvironmentObject private var scanner: Scanner
    @State private var selection: Device.ID?
    @State private var search = ""
    @State private var filter: DeviceFilter = .all
    @State private var sortOrder = [KeyPathComparator(\Device.ip)]

    private var visibleDevices: [Device] {
        var list = scanner.devices
        switch filter {
        case .all:    break
        case .online: list = list.filter(\.isOnline)
        case .named:  list = list.filter { !$0.isAnonymous || $0.customName != nil }
        }
        if !search.isEmpty {
            let needle = search.lowercased()
            list = list.filter { device in
                [device.displayName, device.ipString, device.mac ?? "", device.vendor ?? "",
                 device.model ?? "", device.kind.label]
                    .contains { $0.lowercased().contains(needle) }
            }
        }
        return list.sorted(using: sortOrder)
    }

    private var selectedDevice: Device? {
        scanner.devices.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            NetworkSummaryBar()
            Divider()
            if scanner.isScanning { progressStrip }
            HSplitView {
                deviceTable
                    .frame(minWidth: 520, idealWidth: 900)
                if let selectedDevice {
                    DeviceDetailView(device: selectedDevice)
                        .frame(minWidth: 290, idealWidth: 340, maxWidth: 430)
                }
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle("Netzblick")
        .onAppear { if scanner.devices.isEmpty { scanner.startScan() } }
    }

    // MARK: - Kopfbereich

    private var progressStrip: some View {
        VStack(spacing: 4) {
            ProgressView(value: scanner.progress)
                .progressViewStyle(.linear)
            HStack {
                Text(scanner.phase)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(scanner.progress * 100)) %")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35))
    }

    // MARK: - Tabelle

    private var deviceTable: some View {
        Table(of: Device.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("") { device in
                StatusDot(device: device)
            }
            .width(18)

            TableColumn("Name", value: \.displayName) { device in
                HStack(spacing: 8) {
                    Image(systemName: device.kind.symbol)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.displayName).lineLimit(1)
                        if device.isSelf {
                            Text("dieser Mac").font(.caption2).foregroundStyle(.secondary)
                        } else if device.isGateway {
                            Text("Router / Gateway").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .width(min: 165, ideal: 210)

            TableColumn("IP-Adresse", value: \.ip) { device in
                Text(device.ipString).monospacedDigit()
            }
            .width(min: 108, ideal: 118)

            TableColumn("MAC-Adresse") { device in
                if let mac = device.mac {
                    Text(mac).font(.system(.callout, design: .monospaced)).lineLimit(1)
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .width(min: 150, ideal: 168)

            TableColumn("Hersteller") { device in
                // Bei gewürfelten Adressen gibt es keinen Hersteller – dann ist
                // genau das die Information, die zählt.
                if let vendor = device.vendor ?? device.manufacturer {
                    Text(vendor).lineLimit(1)
                } else if device.hasRandomMAC {
                    Text("zufällige MAC")
                        .foregroundStyle(.secondary)
                        .help("Das Gerät verschleiert seine Hardware-Adresse – bei Smartphones der Normalfall.")
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .width(min: 105, ideal: 140)

            TableColumn("Typ") { device in
                Text(device.kind.label).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 82, ideal: 95)

            TableColumn("Antwort") { device in
                if let rtt = device.rtt {
                    Text(String(format: "%.0f ms", rtt * 1000)).monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("–").foregroundStyle(.tertiary)
                }
            }
            .width(68)
        } rows: {
            ForEach(visibleDevices) { device in
                TableRow(device)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if scanner.devices.isEmpty && !scanner.isScanning {
                ContentUnavailableView {
                    Label("Noch keine Geräte gefunden", systemImage: "wifi.slash")
                } description: {
                    Text("Starte einen Scan, um alle Geräte in deinem Netzwerk zu finden.")
                } actions: {
                    Button("Netzwerk scannen") { scanner.startScan() }
                        .buttonStyle(.borderedProminent)
                }
            } else if visibleDevices.isEmpty && !scanner.devices.isEmpty {
                ContentUnavailableView("Keine Treffer", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("Kein Gerät passt zu Filter und Suchbegriff."))
            }
        }
    }

    // MARK: - Werkzeugleiste

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                scanner.isScanning ? scanner.stopScan() : scanner.startScan()
            } label: {
                Label(scanner.isScanning ? "Stoppen" : "Scannen",
                      systemImage: scanner.isScanning ? "stop.fill" : "arrow.clockwise")
            }
            .help(scanner.isScanning ? "Laufenden Scan abbrechen" : "Netzwerk neu durchsuchen (⌘R)")
        }

        ToolbarItem {
            Menu {
                Picker("Automatisch scannen", selection: $scanner.autoScanMinutes) {
                    Text("Aus").tag(0)
                    Text("Alle 2 Minuten").tag(2)
                    Text("Alle 5 Minuten").tag(5)
                    Text("Alle 15 Minuten").tag(15)
                    Text("Alle 60 Minuten").tag(60)
                }
                .pickerStyle(.inline)
                Divider()
                if scanner.interfaces.count > 1 {
                    Picker("Schnittstelle", selection: Binding(
                        get: { scanner.selectedInterface?.bsdName ?? "" },
                        set: { name in scanner.selectedInterface = scanner.interfaces.first { $0.bsdName == name } })) {
                        ForEach(scanner.interfaces) { interface in
                            Text("\(interface.displayName) – \(interface.cidr)").tag(interface.bsdName)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                }
                Button("Als CSV exportieren …") { exportCSV() }
                Button("Gerätehistorie im Finder zeigen") {
                    NSWorkspace.shared.selectFile(scanner.store.storageDescription, inFileViewerRootedAtPath: "")
                }
            } label: {
                Label("Optionen", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem {
            Picker("Filter", selection: $filter) {
                ForEach(DeviceFilter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
        }

        ToolbarItem {
            TextField("Suchen", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "netzwerk-geraete.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var lines = ["Name;IP;MAC;Hersteller;Typ;Modell;Offene Ports;Zuerst gesehen;Zuletzt gesehen"]
        let formatter = ISO8601DateFormatter()
        for device in visibleDevices {
            let ports = device.openPorts.map(String.init).joined(separator: " ")
            let fields = [device.displayName, device.ipString, device.mac ?? "", device.vendor ?? "",
                          device.kind.label, device.model ?? "", ports,
                          formatter.string(from: device.firstSeen), formatter.string(from: device.lastSeen)]
            lines.append(fields.map { $0.replacingOccurrences(of: ";", with: ",") }.joined(separator: ";"))
        }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Farbiger Punkt: dieser Mac, erreichbar oder zuletzt gesehen.
struct StatusDot: View {
    let device: Device

    private var color: Color {
        if device.isSelf { return .blue }
        return device.isOnline ? .green : .secondary
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .help(device.isOnline ? "Erreichbar" : "Zuletzt gesehen: \(device.lastSeen.germanDateTime)")
    }
}
