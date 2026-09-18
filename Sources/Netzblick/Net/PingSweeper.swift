import Foundation

/// ICMP-Echo-Sweep über ein ganzes Subnetz.
///
/// Nutzt `SOCK_DGRAM`/`IPPROTO_ICMP`, das macOS auch ohne Root-Rechte erlaubt.
/// Nebeneffekt und eigentlicher Trick: Jedes gesendete Paket zwingt den Kernel
/// zu einer ARP-Auflösung. Dadurch tauchen auch Geräte in der ARP-Tabelle auf,
/// die Pings selbst stumm verwerfen.
final class PingSweeper {

    struct Reply {
        let ip: UInt32
        let rtt: TimeInterval
        /// TTL aus dem IP-Header der Antwort – im lokalen Netz ohne Router
        /// dazwischen ist das der Startwert des Betriebssystems.
        let ttl: UInt8
    }

    private var socketDescriptor: Int32 = -1

    deinit { close() }

    func close() {
        if socketDescriptor >= 0 {
            Darwin.close(socketDescriptor)
            socketDescriptor = -1
        }
    }

    /// Sendet Echo-Requests an alle Ziele und meldet eingehende Antworten.
    /// Läuft blockierend – gehört auf einen Hintergrund-Thread.
    /// - Returns: `false`, wenn kein ICMP-Socket geöffnet werden konnte.
    @discardableResult
    func sweep(targets: [UInt32],
               rounds: Int = 2,
               replyWindow: TimeInterval = 1.5,
               isCancelled: () -> Bool = { false },
               onProgress: (Int, Int) -> Void = { _, _ in },
               onReply: (Reply) -> Void) -> Bool {

        guard !targets.isEmpty else { return true }
        socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard socketDescriptor >= 0 else {
            FileHandle.standardError.write(Data("Netzblick: ICMP-Socket nicht verfügbar – \(String(cString: strerror(errno)))\n".utf8))
            return false
        }
        defer { close() }

        let flags = fcntl(socketDescriptor, F_GETFL, 0)
        _ = fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK)
        var bufferSize: Int32 = 256 * 1024
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))

        let identifier = UInt16.random(in: 1...UInt16.max)
        var sendTimes: [UInt32: TimeInterval] = [:]
        var answered: Set<UInt32> = []
        // Der ICMP-Socket bekommt auch Antworten zu sehen, die andere
        // Prozesse ausgelöst haben. Ohne diesen Filter landen fremde
        // Gegenstellen als Phantom-Geräte in der Liste.
        let expected = Set(targets)
        let totalSteps = targets.count * rounds

        for round in 0..<rounds {
            for (index, target) in targets.enumerated() {
                if isCancelled() { return true }
                if answered.contains(target) { continue }
                let now = Date.timeIntervalSinceReferenceDate
                if sendTimes[target] == nil { sendTimes[target] = now }
                send(to: target, identifier: identifier, sequence: UInt16(truncatingIfNeeded: index))
                // Zwischendurch abholen, damit der Empfangspuffer nicht überläuft.
                if index % 24 == 23 {
                    drain(until: 0.004, sendTimes: sendTimes, expected: expected,
                          answered: &answered, onReply: onReply)
                }
                onProgress(round * targets.count + index + 1, totalSteps)
            }
            drain(until: round == rounds - 1 ? replyWindow : 0.25,
                  sendTimes: sendTimes, expected: expected, answered: &answered, onReply: onReply)
        }
        onProgress(totalSteps, totalSteps)
        return true
    }

    // MARK: - Senden

    private func send(to target: UInt32, identifier: UInt16, sequence: UInt16) {
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8                                   // Typ: Echo Request
        packet[1] = 0                                   // Code
        packet[4] = UInt8(identifier >> 8)
        packet[5] = UInt8(identifier & 0xff)
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xff)
        for index in 8..<16 { packet[index] = UInt8(0x40 + index) }
        let sum = Self.checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xff)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = target.bigEndian
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = sendto(socketDescriptor, packet, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    // MARK: - Empfangen

    private func drain(until window: TimeInterval,
                       sendTimes: [UInt32: TimeInterval],
                       expected: Set<UInt32>,
                       answered: inout Set<UInt32>,
                       onReply: (Reply) -> Void) {
        let deadline = Date.timeIntervalSinceReferenceDate + window
        var buffer = [UInt8](repeating: 0, count: 2048)

        while true {
            let remaining = deadline - Date.timeIntervalSinceReferenceDate
            if remaining <= 0 { return }
            var pollDescriptor = pollfd(fd: socketDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(max(1, remaining * 1000)))
            if ready <= 0 { return }

            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received: Int = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(socketDescriptor, &buffer, buffer.count, 0, sa, &fromLength)
                }
            }
            guard received > 0 else { return }

            // Bei SOCK_DGRAM/ICMP liefert Darwin den IPv4-Header mit aus.
            var offset = 0
            var ttl: UInt8 = 0
            if received > 20, buffer[0] >> 4 == 4 {
                offset = Int(buffer[0] & 0x0f) * 4
                ttl = buffer[8]
            }
            guard received >= offset + 8, buffer[offset] == 0 else { continue }   // Typ 0 = Echo Reply

            let source = UInt32(bigEndian: from.sin_addr.s_addr)
            guard source != 0, expected.contains(source), !answered.contains(source) else { continue }
            answered.insert(source)
            let sent = sendTimes[source] ?? Date.timeIntervalSinceReferenceDate
            onReply(Reply(ip: source, rtt: max(0, Date.timeIntervalSinceReferenceDate - sent), ttl: ttl))
        }
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index + 1 < bytes.count {
            sum &+= UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
            index += 2
        }
        if index < bytes.count { sum &+= UInt32(bytes[index]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) &+ (sum >> 16) }
        return UInt16(truncatingIfNeeded: ~sum)
    }
}
