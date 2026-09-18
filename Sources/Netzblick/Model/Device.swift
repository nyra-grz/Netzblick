import Foundation

extension Date {
    /// `Date.formatted` richtet sich nach der Systemsprache, nicht nach der
    /// Locale aus der SwiftUI-Umgebung. Für eine durchgehend deutsche
    /// Oberfläche muss die Sprache deshalb explizit mitgegeben werden.
    private static let german = Locale(identifier: "de_DE")

    var germanDateTime: String {
        formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Date.german))
    }

    var germanTime: String {
        formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Date.german))
    }
}

/// Grobe Geräteklasse – steuert Symbol und Beschriftung in der Liste.
enum DeviceKind: String, Codable, CaseIterable {
    case router, mac, iPhone, iPad, appleTV, appleWatch, homePod
    case windows, linux, android, printer, nas, tv, speaker
    case camera, smartHome, console, phone, unknown

    var label: String {
        switch self {
        case .router:     return "Router"
        case .mac:        return "Mac"
        case .iPhone:     return "iPhone"
        case .iPad:       return "iPad"
        case .appleTV:    return "Apple TV"
        case .appleWatch: return "Apple Watch"
        case .homePod:    return "HomePod"
        case .windows:    return "Windows-PC"
        case .linux:      return "Linux-Rechner"
        case .android:    return "Android-Gerät"
        case .printer:    return "Drucker"
        case .nas:        return "NAS / Server"
        case .tv:         return "Fernseher"
        case .speaker:    return "Lautsprecher"
        case .camera:     return "Kamera"
        case .smartHome:  return "Smart Home"
        case .console:    return "Spielkonsole"
        case .phone:      return "Telefon"
        case .unknown:    return "Unbekannt"
        }
    }

    var symbol: String {
        switch self {
        case .router:     return "wifi.router.fill"
        case .mac:        return "desktopcomputer"
        case .iPhone:     return "iphone"
        case .iPad:       return "ipad"
        case .appleTV:    return "appletv.fill"
        case .appleWatch: return "applewatch"
        case .homePod:    return "homepod.fill"
        case .windows:    return "pc"
        case .linux:      return "terminal.fill"
        case .android:    return "candybarphone"
        case .printer:    return "printer.fill"
        case .nas:        return "externaldrive.connected.to.line.below.fill"
        case .tv:         return "tv.fill"
        case .speaker:    return "hifispeaker.fill"
        case .camera:     return "video.fill"
        case .smartHome:  return "lightbulb.fill"
        case .console:    return "gamecontroller.fill"
        case .phone:      return "teletype"
        case .unknown:    return "questionmark.circle.fill"
        }
    }
}

/// Betriebssystem-Familie, abgeleitet aus dem TTL-Startwert.
///
/// Windows initialisiert die TTL mit 128, alle Unix-artigen Systeme mit 64,
/// viele Netzwerkgeräte mit 255. Im selben Subnetz liegt kein Router
/// dazwischen, der Wert kommt also unverändert an.
enum OSFamily: String, Codable {
    case windows, unixLike, networkDevice

    var label: String {
        switch self {
        case .windows:       return "Windows"
        case .unixLike:      return "Unix-artig – Linux, Android, macOS oder iOS"
        case .networkDevice: return "Netzwerkgerät"
        }
    }
}

/// Ein im Netz gefundenes Gerät, zusammengesetzt aus allen Erkennungsquellen.
struct Device: Identifiable, Hashable, Codable {

    var ip: UInt32
    var mac: String?

    // Namen aus den verschiedenen Quellen – jede für sich eine Teilwahrheit.
    var hostname: String?
    var bonjourName: String?
    var netbiosName: String?
    var ssdpName: String?
    var customName: String?
    /// Titel der Weboberfläche, z. B. „FRITZ!Box 7590“ oder „DiskStation“.
    var webName: String?
    var webServer: String?

    var vendor: String?
    var model: String?
    var manufacturer: String?
    /// Rotierende Bonjour-Kennung – nur zur Anzeige, nie zur Identifikation.
    var bonjourIdentifier: String?

    /// TTL der ICMP-Antwort, Grundlage der Betriebssystem-Schätzung.
    var ttl: UInt8?
    var openPorts: [UInt16] = []
    var bonjourTypes: [String] = []
    var rtt: TimeInterval?

    var isOnline: Bool = true
    var isGateway: Bool = false
    var isSelf: Bool = false
    var note: String = ""

    var firstSeen: Date = Date()
    var lastSeen: Date = Date()

    var ipString: String { SystemNet.ipString(ip) }

    /// Identität in der laufenden Ansicht. Bewusst die IP: Die MAC taucht
    /// erst mitten im Scan auf – wechselte die ID dann, verlöre die Tabelle
    /// die Auswahl des Nutzers.
    var id: String { ipString }

    /// Schlüssel für die dauerhafte Historie. Die MAC überlebt einen
    /// IP-Wechsel per DHCP, deshalb hat sie hier Vorrang.
    var storageKey: String { mac.map { "mac:\($0)" } ?? "ip:\(ipString)" }

    /// Anzeigename nach Verlässlichkeit der Quelle.
    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let bonjourName, !bonjourName.isEmpty { return Device.prettify(bonjourName) }
        if let ssdpName, !ssdpName.isEmpty { return ssdpName }
        if let hostname, !hostname.isEmpty { return Device.prettify(hostname) }
        if let webName, !webName.isEmpty { return webName }
        // NetBIOS liefert oft nur Ableitungen wie „MAC-13118A“ – besser als
        // nichts, aber schlechter als jede echte Namensquelle.
        if let netbiosName, !netbiosName.isEmpty { return netbiosName }
        if isGateway { return "Router" }
        // Ohne Namen zählt Unterscheidbarkeit: Hersteller plus MAC-Endung
        // ergibt für jedes Gerät eine eindeutige, wiedererkennbare Zeile.
        if let vendor {
            return macSuffix.isEmpty ? vendor : "\(vendor) · \(macSuffix)"
        }
        if !macSuffix.isEmpty { return "Gerät · \(macSuffix)" }
        return "Unbekanntes Gerät"
    }

    var osFamily: OSFamily? {
        guard let ttl, ttl > 0 else { return nil }
        switch ttl {
        case 65...128:  return .windows
        case 33...64:   return .unixLike
        case 129...255: return .networkDevice
        default:        return nil
        }
    }

    /// Die letzten drei Oktette der MAC – kurz genug für die Liste und
    /// innerhalb eines Netzes praktisch immer eindeutig.
    var macSuffix: String {
        guard let mac else { return "" }
        return mac.split(separator: ":").suffix(3).joined(separator: ":")
    }

    /// Wahr, wenn kein Name aus einer Netzwerkquelle stammt – genau die
    /// Geräte, die man sich genauer ansehen sollte.
    var isAnonymous: Bool {
        (bonjourName ?? ssdpName ?? hostname ?? webName ?? netbiosName) == nil
    }

    var hasRandomMAC: Bool {
        guard let mac else { return false }
        return VendorDatabase.isRandomized(mac)
    }

    var kind: DeviceKind { Device.inferKind(self) }

    /// Macht aus `Daniels-MacBook-Pro.local.` wieder „Daniels MacBook Pro“.
    static func prettify(_ raw: String) -> String {
        var name = raw
        if name.hasSuffix(".") { name.removeLast() }
        for suffix in [".local", ".fritz.box", ".lan", ".home", ".speedport.ip"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.replacingOccurrences(of: "-", with: " ")
    }

    /// Marken, deren MAC-Präfix in einem WLAN fast immer an einem
    /// Android-Telefon hängt. Bewusst ohne Google und Sony – von denen
    /// stehen genauso oft Lautsprecher und Fernseher im Netz.
    static let androidBrands = [
        "samsung", "xiaomi", "redmi", "huawei", "honor", "oneplus", "oppo",
        "vivo mobile", "realme", "motorola", "nothing technology", "hmd ",
        "fairphone", "tcl", "infinix", "tecno", "meizu", "zte"
    ]

    // MARK: - Gerätetyp ableiten

    static func inferKind(_ device: Device) -> DeviceKind {
        let haystack = [device.bonjourName, device.ssdpName, device.hostname, device.netbiosName,
                        device.webName, device.webServer,
                        device.model, device.vendor, device.manufacturer, device.customName]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let types = device.bonjourTypes.joined(separator: " ").lowercased()
        let ports = Set(device.openPorts)

        if device.isGateway { return .router }

        // Modellkennungen sind die zuverlässigste Quelle.
        if haystack.contains("macbook") || haystack.contains("imac") || haystack.contains("macmini")
            || haystack.contains("macpro") || haystack.contains("macstudio") || haystack.contains("mac studio") { return .mac }
        if haystack.contains("iphone") { return .iPhone }
        if haystack.contains("ipad") { return .iPad }
        if haystack.contains("appletv") || haystack.contains("apple tv") { return .appleTV }
        if haystack.contains("watch") && haystack.contains("apple") { return .appleWatch }
        if haystack.contains("homepod") || haystack.contains("audioaccessory") { return .homePod }

        if ports.contains(62078) { return .iPhone }
        if Device.androidBrands.contains(where: { haystack.contains($0) }) { return .android }
        if types.contains("_androidtvremote2") { return .tv }
        if types.contains("_googlecast") || ports.contains(8009) { return .tv }
        if types.contains("_ipp") || types.contains("_printer") || types.contains("_pdl-datastream")
            || ports.contains(9100) || ports.contains(631) || ports.contains(515) { return .printer }
        if types.contains("_raop") || types.contains("_spotify-connect") || haystack.contains("sonos") { return .speaker }
        if types.contains("_hap") || types.contains("_matter") || types.contains("_esphomelib")
            || haystack.contains("shelly") || haystack.contains("tasmota") || haystack.contains("hue")
            || haystack.contains("tuya") || ports.contains(1883) || ports.contains(8123) { return .smartHome }

        if haystack.contains("fritz") || haystack.contains("speedport") || haystack.contains("router")
            || haystack.contains("gateway") || haystack.contains("repeater") || haystack.contains("fritz!box") { return .router }
        if haystack.contains("synology") || haystack.contains("qnap") || haystack.contains("diskstation")
            || haystack.contains("nas") || ports.contains(32400) { return .nas }
        if haystack.contains("playstation") || haystack.contains("xbox") || haystack.contains("nintendo") { return .console }
        if haystack.contains("samsung") && (types.contains("tv") || haystack.contains("tv")) { return .tv }
        if haystack.contains("bravia") || haystack.contains("lg tv") || haystack.contains("webos")
            || haystack.contains("firetv") || haystack.contains("chromecast") { return .tv }
        if haystack.contains("camera") || haystack.contains("kamera") || haystack.contains("reolink")
            || haystack.contains("hikvision") { return .camera }

        if ports.contains(445) || ports.contains(139) || haystack.contains("windows") { return .windows }
        // Windows blockiert in fremden Netzen alle eingehenden Ports; die TTL
        // verrät es trotzdem.
        if device.osFamily == .windows { return .windows }
        if types.contains("_workstation") || types.contains("_afpovertcp") || ports.contains(548) { return .mac }
        if haystack.contains("android") || haystack.contains("xiaomi") || haystack.contains("oneplus") { return .android }
        if haystack.contains("raspberry") || (ports.contains(22) && ports.contains(80)) { return .linux }
        if ports.contains(5060) { return .phone }
        if ports.contains(22) { return .linux }

        return .unknown
    }
}
