import Foundation

/// Antwort eines UPnP-Geräts auf eine SSDP-Suche.
struct SSDPResponse {
    let ip: UInt32
    var server: String?
    var location: String?
    var friendlyName: String?
    var manufacturer: String?
    var modelName: String?
}

/// UPnP/SSDP-Suche per Multicast.
///
/// Der wichtigste Kanal für alles, was kein Bonjour spricht: Fernseher,
/// Router, Spielkonsolen, Windows-Rechner und viele Smart-Home-Geräte
/// melden hier Hersteller- und Modellnamen im Klartext.
enum SSDPDiscovery {

    static func discover(duration: TimeInterval = 3.0, fetchDetails: Bool = true) -> [UInt32: SSDPResponse] {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { return [:] }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var ttl: Int32 = 2
        setsockopt(descriptor, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(1900).bigEndian
        target.sin_addr.s_addr = inet_addr("239.255.255.250")

        let message = """
        M-SEARCH * HTTP/1.1\r
        HOST: 239.255.255.250:1900\r
        MAN: "ssdp:discover"\r
        MX: 2\r
        ST: ssdp:all\r
        \r

        """
        let payload = [UInt8](message.utf8)

        // Zwei Anläufe, weil UDP-Multicast gern einzelne Pakete verliert.
        for _ in 0..<2 {
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(descriptor, payload, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            usleep(150_000)
        }

        var responses: [UInt32: SSDPResponse] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(duration)

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&pollDescriptor, 1, Int32(max(1, remaining * 1000))) > 0 else { break }

            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received: Int = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(descriptor, &buffer, buffer.count, 0, sa, &fromLength)
                }
            }
            guard received > 0, let text = String(bytes: buffer[0..<received], encoding: .utf8) else { continue }

            let ip = UInt32(bigEndian: from.sin_addr.s_addr)
            var response = responses[ip] ?? SSDPResponse(ip: ip, server: nil, location: nil,
                                                         friendlyName: nil, manufacturer: nil, modelName: nil)
            for line in text.split(whereSeparator: \.isNewline) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).uppercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if key == "SERVER", response.server == nil { response.server = value }
                if key == "LOCATION", response.location == nil { response.location = value }
            }
            responses[ip] = response
        }

        if fetchDetails { enrich(&responses) }
        return responses
    }

    /// Lädt die Gerätebeschreibung und zieht Klarnamen daraus.
    private static func enrich(_ responses: inout [UInt32: SSDPResponse]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var details: [UInt32: (String?, String?, String?)] = [:]
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 2.5
            return configuration
        }())

        for (ip, response) in responses.prefix(24) {
            guard let location = response.location, let url = URL(string: location) else { continue }
            group.enter()
            session.dataTask(with: url) { data, _, _ in
                defer { group.leave() }
                guard let data, let xml = String(data: data, encoding: .utf8) else { return }
                let values = (tag("friendlyName", in: xml), tag("manufacturer", in: xml), tag("modelName", in: xml))
                lock.lock(); details[ip] = values; lock.unlock()
            }.resume()
        }
        _ = group.wait(timeout: .now() + 8)

        lock.lock()
        for (ip, value) in details {
            responses[ip]?.friendlyName = value.0
            responses[ip]?.manufacturer = value.1
            responses[ip]?.modelName = value.2
        }
        lock.unlock()
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"),
              let close = xml.range(of: "</\(name)>"), open.upperBound < close.lowerBound else { return nil }
        let value = String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
