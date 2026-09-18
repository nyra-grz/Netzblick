import Foundation

/// Liest den Seitentitel und den `Server`-Header einer Geräte-Weboberfläche.
///
/// In verwalteten Netzen, die Multicast zwischen Clients filtern, ist das oft
/// der einzige Kanal, der überhaupt noch einen Klarnamen liefert – Router,
/// Drucker, NAS-Systeme und Kameras verraten ihr Modell im Titel.
enum WebBanner {

    struct Result {
        var title: String?
        var server: String?
    }

    static let webPorts: [UInt16] = [80, 8080, 443, 8443, 5000]

    /// Fragt der Reihe nach die offenen Web-Ports ab und nimmt den ersten
    /// brauchbaren Titel.
    static func probe(ip: UInt32, openPorts: [UInt16], timeout: TimeInterval = 1.5) -> Result? {
        let candidates = webPorts.filter { openPorts.contains($0) }
        guard !candidates.isEmpty else { return nil }
        var fallback: Result?
        for port in candidates {
            guard let result = request(ip: ip, port: port, timeout: timeout) else { continue }
            if result.title != nil { return result }
            if fallback == nil { fallback = result }
        }
        return fallback
    }

    private static func request(ip: UInt32, port: UInt16, timeout: TimeInterval) -> Result? {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var window = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = ip.bigEndian
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        // Bewusst reines HTTP: Ein TLS-Handshake würde hier nur den
        // Zertifikatsnamen liefern, und viele Geräte antworten auf 443
        // ohnehin mit einer Weiterleitung im Klartext.
        let host = SystemNet.ipString(ip)
        let request = "GET / HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: Netzblick\r\nAccept: text/html\r\nConnection: close\r\n\r\n"
        let sent = Array(request.utf8).withUnsafeBufferPointer { send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent > 0 else { return nil }

        var raw = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while raw.count < 16_384 {
            let received = recv(descriptor, &chunk, chunk.count, 0)
            if received <= 0 { break }
            raw.append(contentsOf: chunk[0..<received])
        }
        guard !raw.isEmpty else { return nil }
        guard let text = String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .isoLatin1) else { return nil }

        var result = Result()
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.uppercased().hasPrefix("SERVER:") else { continue }
            let value = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { result.server = String(value.prefix(60)) }
            break
        }
        result.title = extractTitle(from: text)
        return result.title == nil && result.server == nil ? nil : result
    }

    private static func extractTitle(from html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
              let closeTag = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title>", options: .caseInsensitive,
                                     range: closeTag.upperBound..<html.endIndex) else { return nil }
        var title = String(html[closeTag.upperBound..<close.lowerBound])
        title = title.replacingOccurrences(of: "\n", with: " ")
        title = title.replacingOccurrences(of: "&amp;", with: "&")
        title = title.replacingOccurrences(of: "&nbsp;", with: " ")
        title = title.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return isUseful(title) ? String(title.prefix(48)) : nil
    }

    /// Fehlerseiten und Platzhalter taugen nicht als Gerätename.
    private static func isUseful(_ title: String) -> Bool {
        guard title.count >= 3, title.count <= 60 else { return false }
        let lowered = title.lowercased()
        let junk = ["bad request", "unauthorized", "forbidden", "not found", "error",
                    "index of /", "untitled", "document", "redirect", "moved", "login",
                    "400", "401", "403", "404", "500", "web page blocked"]
        return !junk.contains { lowered.contains($0) }
    }
}
