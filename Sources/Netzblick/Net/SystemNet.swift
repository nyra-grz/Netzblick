import Foundation
import SystemConfiguration

/// Beschreibt eine aktive IPv4-Schnittstelle samt Subnetz.
struct LocalInterface: Hashable, Identifiable {
    let bsdName: String
    let displayName: String
    let ipv4: UInt32
    let netmask: UInt32
    let mac: String?

    var id: String { bsdName }
    var ipString: String { SystemNet.ipString(ipv4) }
    var netmaskString: String { SystemNet.ipString(netmask) }
    var prefixLength: Int { netmask.nonzeroBitCount }
    var networkAddress: UInt32 { ipv4 & netmask }
    var broadcastAddress: UInt32 { networkAddress | ~netmask }
    var cidr: String { "\(SystemNet.ipString(networkAddress))/\(prefixLength)" }

    /// Anzahl adressierbarer Hosts im Subnetz (ohne Netz- und Broadcast-Adresse).
    var hostCount: Int {
        let span = Int(broadcastAddress) - Int(networkAddress)
        return max(0, span - 1)
    }

    /// Alle zu scannenden Host-Adressen. Sehr große Netze werden auf ein
    /// Fenster rund um die eigene Adresse begrenzt, damit ein Scan endlich bleibt.
    func hostAddresses(limit: Int = 1024) -> [UInt32] {
        let first = networkAddress &+ 1
        let last = broadcastAddress &- 1
        guard last >= first else { return [] }
        if hostCount <= limit {
            return Array(first...last)
        }
        let half = UInt32(limit / 2)
        let lower = ipv4 &- half < first ? first : ipv4 &- half
        let upper = min(last, lower &+ UInt32(limit) &- 1)
        return Array(lower...upper)
    }

    var isTruncatedScan: Bool { hostCount > 1024 }
}

enum SystemNet {

    // MARK: - Adress-Helfer

    static func ipString(_ addr: UInt32) -> String {
        "\((addr >> 24) & 0xff).\((addr >> 16) & 0xff).\((addr >> 8) & 0xff).\(addr & 0xff)"
    }

    static func ipValue(_ string: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// Normalisiert MAC-Schreibweisen wie `1:0:5e:0:0:fb` auf `01:00:5E:00:00:FB`.
    static func normalizeMAC(_ raw: String) -> String? {
        let parts = raw.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var octets: [String] = []
        for part in parts {
            guard part.count <= 2, let value = UInt8(part, radix: 16) else { return nil }
            octets.append(String(format: "%02X", value))
        }
        return octets.joined(separator: ":")
    }

    // MARK: - Schnittstellen

    /// Liefert alle aktiven IPv4-Schnittstellen, die primäre zuerst.
    static func activeInterfaces() -> [LocalInterface] {
        var displayNames: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for item in all {
                if let bsd = SCNetworkInterfaceGetBSDName(item) as String?,
                   let name = SCNetworkInterfaceGetLocalizedDisplayName(item) as String? {
                    displayNames[bsd] = name
                }
            }
        }

        var macs: [String: String] = [:]
        var addresses: [(name: String, ip: UInt32, mask: UInt32)] = []

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return [] }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
            guard let sa = entry.pointee.ifa_addr else { continue }

            if sa.pointee.sa_family == UInt8(AF_LINK) {
                sa.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl in
                    guard dl.pointee.sdl_alen == 6 else { return }
                    withUnsafeBytes(of: dl.pointee.sdl_data) { bytes in
                        let offset = Int(dl.pointee.sdl_nlen)
                        guard offset + 6 <= bytes.count else { return }
                        let octets = (0..<6).map { String(format: "%02X", bytes[offset + $0]) }
                        macs[name] = octets.joined(separator: ":")
                    }
                }
            } else if sa.pointee.sa_family == UInt8(AF_INET), let maskPtr = entry.pointee.ifa_netmask {
                let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                guard ip != 0, mask != 0, (ip >> 24) != 127 else { continue }
                addresses.append((name, ip, mask))
            }
        }

        let primaryName = defaultRoute()?.interface
        var result = addresses.map {
            LocalInterface(bsdName: $0.name,
                           displayName: displayNames[$0.name] ?? $0.name,
                           ipv4: $0.ip, netmask: $0.mask, mac: macs[$0.name])
        }
        result.sort { lhs, rhs in
            if lhs.bsdName == primaryName { return true }
            if rhs.bsdName == primaryName { return false }
            return lhs.bsdName < rhs.bsdName
        }
        return result
    }

    // MARK: - Standard-Route

    struct DefaultRoute {
        let gateway: UInt32
        let interface: String
    }

    /// Ermittelt Gateway und Interface der Standard-Route aus der Kernel-Routingtabelle.
    static func defaultRoute() -> DefaultRoute? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buffer, &needed, nil, 0) == 0 else { return nil }

        var found: DefaultRoute?
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= needed {
                let message = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self)
                let length = Int(message.pointee.rtm_msglen)
                guard length > 0, offset + length <= needed else { break }
                defer { offset += length }

                let flags = message.pointee.rtm_flags
                guard flags & RTF_UP != 0, flags & RTF_GATEWAY != 0 else { continue }

                let addrs = parseAddresses(base: base.advanced(by: offset + MemoryLayout<rt_msghdr>.size),
                                           available: length - MemoryLayout<rt_msghdr>.size,
                                           bitmask: message.pointee.rtm_addrs)
                guard let destination = addrs[RTA_DST], destination.family == UInt8(AF_INET),
                      destination.ipv4 == 0,
                      let gateway = addrs[RTA_GATEWAY], gateway.family == UInt8(AF_INET) else { continue }

                let index = Int(message.pointee.rtm_index)
                found = DefaultRoute(gateway: gateway.ipv4, interface: interfaceName(index: index) ?? "")
                break
            }
        }
        return found
    }

    private struct RouteAddress {
        let family: UInt8
        let ipv4: UInt32
    }

    /// Läuft die an eine Routing-Nachricht angehängten sockaddr-Strukturen entlang.
    private static func parseAddresses(base: UnsafeRawPointer, available: Int, bitmask: Int32) -> [Int32: RouteAddress] {
        var result: [Int32: RouteAddress] = [:]
        var cursor = 0
        for bit in 0..<8 {
            let flag = Int32(1 << bit)
            guard bitmask & flag != 0 else { continue }
            guard cursor + MemoryLayout<sockaddr>.stride <= available else { break }
            let sa = base.advanced(by: cursor).assumingMemoryBound(to: sockaddr.self)
            let saLength = Int(sa.pointee.sa_len)
            var ipv4: UInt32 = 0
            if sa.pointee.sa_family == UInt8(AF_INET), saLength >= MemoryLayout<sockaddr_in>.size {
                ipv4 = base.advanced(by: cursor).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            }
            result[flag] = RouteAddress(family: sa.pointee.sa_family, ipv4: ipv4)
            cursor += saLength == 0 ? 4 : (saLength + 3) & ~3
        }
        return result
    }

    private static func interfaceName(index: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
        guard if_indextoname(UInt32(index), &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Nachbarschaftstabelle (ARP)

    /// IP → MAC aus dem ARP-Cache des Systems.
    ///
    /// macOS 26/27 liefert Link-Layer-Adressen über `sysctl` nur noch anonymisiert
    /// (`02:00:00:00:00:00`) an nicht privilegierte Prozesse. Deshalb ist
    /// `/usr/sbin/arp` die primäre Quelle, `sysctl` die Rückfallebene.
    static func arpTable() -> [UInt32: String] {
        var table = arpViaTool()
        for (ip, mac) in arpViaSysctl() where table[ip] == nil {
            table[ip] = mac
        }
        return table
    }

    private static func arpViaTool() -> [UInt32: String] {
        guard let output = runTool("/usr/sbin/arp", ["-an"]) else { return [:] }
        var table: [UInt32: String] = [:]
        for line in output.split(separator: "\n") {
            guard let openParen = line.firstIndex(of: "("),
                  let closeParen = line.firstIndex(of: ")"),
                  openParen < closeParen else { continue }
            let ipText = String(line[line.index(after: openParen)..<closeParen])
            guard let ip = ipValue(ipText) else { continue }
            let rest = line[line.index(after: closeParen)...]
            guard let atRange = rest.range(of: " at ") else { continue }
            let macField = rest[atRange.upperBound...].prefix { $0 != " " }
            guard let mac = normalizeMAC(String(macField)) else { continue }
            table[ip] = mac
        }
        return table
    }

    private static func arpViaSysctl() -> [UInt32: String] {
        // Adressfamilie 0 statt AF_INET: seit macOS 26 liefert der gefilterte
        // Aufruf sonst einen leeren Puffer.
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_FLAGS, Int32(RTF_LLINFO)]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: needed)
        guard sysctl(&mib, 6, &buffer, &needed, nil, 0) == 0 else { return [:] }

        var table: [UInt32: String] = [:]
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= needed {
                let message = base.advanced(by: offset).assumingMemoryBound(to: rt_msghdr.self)
                let length = Int(message.pointee.rtm_msglen)
                guard length > 0, offset + length <= needed else { break }
                defer { offset += length }

                let payload = base.advanced(by: offset + MemoryLayout<rt_msghdr>.size)
                let sa = payload.assumingMemoryBound(to: sockaddr.self)
                guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }
                let saLength = Int(sa.pointee.sa_len)
                let rounded = saLength == 0 ? 4 : (saLength + 3) & ~3
                let ip = payload.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian

                let dl = payload.advanced(by: rounded).assumingMemoryBound(to: sockaddr_dl.self)
                guard dl.pointee.sdl_family == UInt8(AF_LINK), dl.pointee.sdl_alen == 6 else { continue }
                withUnsafeBytes(of: dl.pointee.sdl_data) { bytes in
                    let start = Int(dl.pointee.sdl_nlen)
                    guard start + 6 <= bytes.count else { return }
                    let octets = (0..<6).map { String(format: "%02X", bytes[start + $0]) }
                    let mac = octets.joined(separator: ":")
                    // Anonymisierte Platzhalter verwerfen.
                    guard mac != "02:00:00:00:00:00", mac != "FF:FF:FF:FF:FF:FF" else { return }
                    table[ip] = mac
                }
            }
        }
        return table
    }

    static func runTool(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        return String(data: data, encoding: .utf8)
    }
}
