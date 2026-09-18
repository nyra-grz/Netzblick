import Foundation

enum NameResolver {

    /// Reverse-DNS über den Resolver des Systems – beantwortet im Heimnetz
    /// meist der Router (Fritz!Box & Co. kennen die DHCP-Namen) oder das
    /// Gerät selbst per mDNS.
    static func hostname(for ip: UInt32, timeout: TimeInterval = 2.0) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        DispatchQueue.global(qos: .userInitiated).async {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = ip.bigEndian
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
                }
            }
            if status == 0 {
                let name = String(cString: host)
                if !name.isEmpty, SystemNet.ipValue(name) == nil { result = name }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
        return result
    }

    /// NetBIOS-Node-Status-Abfrage (UDP 137) – liefert den Rechnernamen von
    /// Windows-PCs und Samba-Servern, die sonst anonym bleiben.
    static func netbiosName(for ip: UInt32, timeout: TimeInterval = 0.8) -> String? {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        // Node-Status-Anfrage auf den Wildcard-Namen "*".
        var query: [UInt8] = [0x9d, 0x1e, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        query.append(0x20)
        query.append(contentsOf: [UInt8]("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8))
        query.append(contentsOf: [0x00, 0x00, 0x21, 0x00, 0x01])

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(137).bigEndian
        address.sin_addr.s_addr = ip.bigEndian
        let sent = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(descriptor, query, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { return nil }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&pollDescriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let received = recv(descriptor, &buffer, buffer.count, 0)
        guard received > 56 else { return nil }

        // Header 12 + Name 34 + Typ/Klasse/TTL/Länge 10 → Anzahl der Namen.
        let countIndex = 56
        guard countIndex < received else { return nil }
        let nameCount = Int(buffer[countIndex])
        var offset = countIndex + 1
        for _ in 0..<nameCount {
            guard offset + 18 <= received else { break }
            let raw = String(bytes: buffer[offset..<(offset + 15)], encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let suffix = buffer[offset + 15]
            let flags = UInt16(buffer[offset + 16]) << 8 | UInt16(buffer[offset + 17])
            let isGroup = flags & 0x8000 != 0
            // Suffix 0x00 = Workstation-Dienst, Gruppennamen sind Arbeitsgruppen.
            if suffix == 0x00, !isGroup, !raw.isEmpty, raw != "*" { return raw }
            offset += 18
        }
        return nil
    }
}
