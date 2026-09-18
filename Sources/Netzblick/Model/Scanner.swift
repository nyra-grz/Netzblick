import Foundation
import Combine

/// Thread-sicheres Abbruch-Signal zwischen Oberfläche und Scan-Thread.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    func cancel() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}

/// Führt alle Erkennungsverfahren zu einer Geräteliste zusammen.
///
/// Ablauf eines Scans:
/// 1. ICMP-Sweep über das gesamte Subnetz (nebenbei füllt sich der ARP-Cache)
/// 2. ARP-Tabelle lesen – zeigt auch Geräte, die Pings ignorieren
/// 3. Bonjour und SSDP liefern Klarnamen, Modelle und Hersteller
/// 4. Reverse-DNS und NetBIOS für alles, was dann noch namenlos ist
/// 5. Portscan zur Bestimmung des Gerätetyps
@MainActor
final class Scanner: ObservableObject {

    @Published private(set) var devices: [Device] = []
    @Published private(set) var isScanning = false
    @Published private(set) var phase = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastScan: Date?
    @Published private(set) var interfaces: [LocalInterface] = []
    @Published private(set) var gateway: UInt32?
    @Published var selectedInterface: LocalInterface?
    /// Falsch, wenn kein ICMP-Socket zur Verfügung stand. Dann stammt die
    /// Erreichbarkeit aus TCP-Tests und es gibt keine Antwortzeiten.
    @Published private(set) var icmpAvailable = true
    @Published var autoScanMinutes: Int = 0 {
        didSet { restartTimer() }
    }

    let store = DeviceStore()
    private let cancellation = CancellationFlag()
    private var timer: Timer?
    private let workQueue = DispatchQueue(label: "netzblick.scan", qos: .userInitiated)

    init() {
        refreshInterfaces()
    }

    func refreshInterfaces() {
        interfaces = SystemNet.activeInterfaces()
        gateway = SystemNet.defaultRoute()?.gateway
        // Wichtig: den gemerkten Eintrag ersetzen, nicht nur behalten – bei
        // einem Netzwechsel behält er sonst die alte IP und alles verrutscht.
        if let current = selectedInterface,
           let fresh = interfaces.first(where: { $0.bsdName == current.bsdName }) {
            selectedInterface = fresh
        } else {
            selectedInterface = interfaces.first
        }
    }

    // MARK: - Steuerung

    func startScan() {
        guard !isScanning else { return }
        refreshInterfaces()
        guard let interface = selectedInterface else {
            phase = "Keine aktive Netzwerkverbindung gefunden"
            return
        }
        cancellation.reset()
        isScanning = true
        progress = 0
        phase = "Scan wird vorbereitet …"

        // Treffer aus einem anderen Netz verwerfen (z. B. nach WLAN-Wechsel);
        // der Rest bleibt stehen und gilt bis zum Wiederfinden als offline.
        let network = interface.networkAddress
        let mask = interface.netmask
        devices = devices.filter { $0.ip & mask == network }
        for index in devices.indices {
            devices[index].isOnline = false
            devices[index].rtt = nil
        }

        let gatewayAddress = gateway
        workQueue.async { [weak self] in
            self?.performScan(interface: interface, gateway: gatewayAddress)
        }
    }

    func stopScan() {
        cancellation.cancel()
        phase = "Wird abgebrochen …"
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard autoScanMinutes > 0 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Double(autoScanMinutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startScan() }
        }
    }

    // MARK: - Bearbeitung durch den Nutzer

    func updateDevice(id: String, customName: String?, note: String) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].customName = customName?.isEmpty == true ? nil : customName
        devices[index].note = note
        store.record([devices[index]])
    }

    // MARK: - Scan-Durchlauf (Hintergrund)

    private nonisolated func performScan(interface: LocalInterface, gateway: UInt32?) {
        let targets = interface.hostAddresses()
        var found: [UInt32: Device] = [:]
        let lock = NSLock()

        func upsert(_ ip: UInt32, _ mutate: (inout Device) -> Void) {
            lock.lock()
            var device = found[ip] ?? Device(ip: ip)
            mutate(&device)
            found[ip] = device
            lock.unlock()
        }

        func publish(_ phaseText: String? = nil, _ fraction: Double? = nil) {
            lock.lock()
            let snapshot = Array(found.values)
            lock.unlock()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.mergeIntoUI(snapshot)
                if let phaseText { self.phase = phaseText }
                if let fraction { self.progress = fraction }
            }
        }

        // --- Bonjour und SSDP laufen parallel zum Ping-Sweep ---
        let discoveryGroup = DispatchGroup()
        var bonjourServices: [BonjourService] = []
        var ssdpResponses: [UInt32: SSDPResponse] = [:]

        discoveryGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            // Der Browser muss den ganzen Suchlauf über am Leben bleiben –
            // sonst räumt ARC ihn weg, bevor Antworten eintreffen.
            let browser = BonjourBrowser()
            withExtendedLifetime(browser) {
                bonjourServices = browser.browse(duration: 5.0)
            }
            discoveryGroup.leave()
        }
        discoveryGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            ssdpResponses = SSDPDiscovery.discover(duration: 3.5)
            discoveryGroup.leave()
        }

        // --- 1. ICMP-Sweep ---
        Task { @MainActor [weak self] in
            self?.phase = "Durchsuche \(interface.cidr) – \(targets.count) Adressen …"
        }
        let sweeper = PingSweeper()
        let icmpAvailable = sweeper.sweep(
            targets: targets,
            rounds: 2,
            isCancelled: { [cancellation] in cancellation.isCancelled },
            onProgress: { done, total in
                let fraction = Double(done) / Double(max(1, total)) * 0.45
                Task { @MainActor [weak self] in self?.progress = fraction }
            },
            onReply: { reply in
                upsert(reply.ip) { device in
                    device.isOnline = true
                    device.rtt = reply.rtt
                    if reply.ttl > 0 { device.ttl = reply.ttl }
                    device.lastSeen = Date()
                }
                publish()
            })

        Task { @MainActor [weak self] in self?.icmpAvailable = icmpAvailable }
        if cancellation.isCancelled { finish(cancelled: true); return }

        // --- 2. ARP-Tabelle: zeigt auch stumme Geräte ---
        publish("Lese ARP-Tabelle …", 0.5)
        let arp = SystemNet.arpTable()
        let scanRange = Set(targets)
        for (ip, mac) in arp where scanRange.contains(ip) || ip == gateway {
            upsert(ip) { device in
                device.mac = mac
                device.vendor = VendorDatabase.shared.vendor(for: mac)
                device.lastSeen = Date()
            }
        }

        // Ohne ICMP-Socket bleibt als Lebenszeichen nur ein kurzer TCP-Test.
        if !icmpAvailable {
            publish("Prüfe Erreichbarkeit (TCP) …", 0.55)
            let candidates = Array(scanRange)
            DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
                let ip = candidates[index]
                for port: UInt16 in [80, 443, 22, 445] where PortScanner.probe(ip: ip, port: port, timeout: 0.35) {
                    upsert(ip) { $0.isOnline = true }
                    break
                }
            }
        }

        // Eigenes Gerät und Router gehören immer in die Liste.
        upsert(interface.ipv4) { device in
            device.isSelf = true
            device.isOnline = true
            device.mac = device.mac ?? interface.mac
            device.hostname = device.hostname ?? Host.current().localizedName
            if let mac = device.mac { device.vendor = VendorDatabase.shared.vendor(for: mac) }
        }
        if let gateway {
            upsert(gateway) { device in
                device.isGateway = true
                device.isOnline = true
            }
        }
        publish(nil, 0.6)

        // --- 3. Ergebnisse der Namensdienste einarbeiten ---
        publish("Werte Bonjour und UPnP aus …", 0.62)
        discoveryGroup.wait()

        for service in bonjourServices {
            guard let ip = service.ip else { continue }
            upsert(ip) { device in
                if device.bonjourName == nil || service.type.contains("device-info") {
                    device.bonjourName = service.name
                }
                if !device.bonjourTypes.contains(service.type) { device.bonjourTypes.append(service.type) }
                if let model = service.model, device.model == nil { device.model = model }
                if device.bonjourIdentifier == nil { device.bonjourIdentifier = service.advertisedIdentifier }
                device.isOnline = true
            }
        }
        for (ip, response) in ssdpResponses {
            upsert(ip) { device in
                device.ssdpName = response.friendlyName
                device.manufacturer = response.manufacturer
                if device.model == nil { device.model = response.modelName }
                if device.vendor == nil { device.vendor = response.manufacturer }
                device.isOnline = true
            }
        }
        publish(nil, 0.68)

        if cancellation.isCancelled { finish(cancelled: true); return }

        // --- 4. Reverse-DNS und NetBIOS ---
        lock.lock()
        let hosts = Array(found.keys)
        lock.unlock()
        publish("Löse Namen auf (\(hosts.count) Geräte) …", 0.7)

        DispatchQueue.concurrentPerform(iterations: hosts.count) { index in
            let ip = hosts[index]
            if let name = NameResolver.hostname(for: ip) {
                upsert(ip) { $0.hostname = name }
            }
        }
        publish(nil, 0.8)

        lock.lock()
        let anonymous = found.values.filter { $0.isAnonymous }.map(\.ip)
        lock.unlock()
        if !anonymous.isEmpty {
            DispatchQueue.concurrentPerform(iterations: anonymous.count) { index in
                let ip = anonymous[index]
                if let name = NameResolver.netbiosName(for: ip) {
                    upsert(ip) { $0.netbiosName = name }
                }
            }
        }
        publish(nil, 0.85)

        if cancellation.isCancelled { finish(cancelled: true); return }

        // --- 5. Portscan für die Gerätetyp-Erkennung ---
        publish("Prüfe offene Dienste …", 0.87)
        lock.lock()
        let portTargets = Array(found.keys)
        lock.unlock()
        DispatchQueue.concurrentPerform(iterations: portTargets.count) { index in
            let ip = portTargets[index]
            let open = PortScanner.scan(ip: ip)
            if !open.isEmpty {
                upsert(ip) { device in
                    device.openPorts = open
                    device.isOnline = true
                }
            }
        }
        publish(nil, 0.94)

        // --- 6. Weboberflächen auslesen ---
        lock.lock()
        let webHosts = found.values
            .filter { !$0.openPorts.filter(WebBanner.webPorts.contains).isEmpty }
            .map(\.ip)
        lock.unlock()
        if !webHosts.isEmpty {
            publish("Lese Weboberflächen (\(webHosts.count)) …", 0.95)
            DispatchQueue.concurrentPerform(iterations: webHosts.count) { index in
                let ip = webHosts[index]
                lock.lock()
                let ports = found[ip]?.openPorts ?? []
                lock.unlock()
                guard let banner = WebBanner.probe(ip: ip, openPorts: ports) else { return }
                upsert(ip) { device in
                    device.webName = banner.title
                    device.webServer = banner.server
                }
            }
        }

        publish("Fertig", 1.0)
        finish(cancelled: false)
    }

    private nonisolated func finish(cancelled: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isScanning = false
            self.lastScan = Date()
            let online = self.devices.filter(\.isOnline).count
            self.phase = cancelled ? "Scan abgebrochen" : "\(online) \(online == 1 ? "Gerät" : "Geräte") gefunden"
            self.progress = cancelled ? 0 : 1
            self.finalizeDevices()
        }
    }

    // MARK: - Zusammenführen auf dem Main-Thread

    private func mergeIntoUI(_ snapshot: [Device]) {
        var byIP = Dictionary(uniqueKeysWithValues: devices.map { ($0.ip, $0) })
        for var incoming in snapshot {
            if var existing = byIP[incoming.ip] {
                existing.mac = incoming.mac ?? existing.mac
                existing.vendor = incoming.vendor ?? existing.vendor
                existing.hostname = incoming.hostname ?? existing.hostname
                existing.bonjourName = incoming.bonjourName ?? existing.bonjourName
                existing.netbiosName = incoming.netbiosName ?? existing.netbiosName
                existing.ssdpName = incoming.ssdpName ?? existing.ssdpName
                existing.model = incoming.model ?? existing.model
                existing.manufacturer = incoming.manufacturer ?? existing.manufacturer
                existing.bonjourIdentifier = incoming.bonjourIdentifier ?? existing.bonjourIdentifier
                existing.webName = incoming.webName ?? existing.webName
                existing.webServer = incoming.webServer ?? existing.webServer
                existing.rtt = incoming.rtt ?? existing.rtt
                existing.ttl = incoming.ttl ?? existing.ttl
                if !incoming.openPorts.isEmpty { existing.openPorts = incoming.openPorts }
                if !incoming.bonjourTypes.isEmpty { existing.bonjourTypes = incoming.bonjourTypes }
                existing.isOnline = existing.isOnline || incoming.isOnline
                existing.isGateway = existing.isGateway || incoming.isGateway
                existing.isSelf = existing.isSelf || incoming.isSelf
                existing.lastSeen = max(existing.lastSeen, incoming.lastSeen)
                byIP[incoming.ip] = existing
            } else {
                store.apply(to: &incoming)
                byIP[incoming.ip] = incoming
            }
        }
        devices = byIP.values.sorted { $0.ip < $1.ip }
    }

    private func finalizeDevices() {
        for index in devices.indices {
            if let stored = store.known(devices[index].storageKey) {
                devices[index].firstSeen = stored.firstSeen
                devices[index].customName = stored.customName
                devices[index].note = stored.note
            }
        }
        store.record(devices)
    }
}
