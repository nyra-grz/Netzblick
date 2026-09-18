import Foundation

/// Bekannte Dienste hinter TCP-Ports – die Basis der Gerätetyp-Erkennung.
struct PortInfo {
    let port: UInt16
    let service: String
    let hint: String?
}

enum PortScanner {

    /// Ports, die bei Heimnetz-Geräten etwas über den Gerätetyp verraten.
    static let wellKnown: [PortInfo] = [
        PortInfo(port: 21,    service: "FTP",          hint: nil),
        PortInfo(port: 22,    service: "SSH",          hint: nil),
        PortInfo(port: 23,    service: "Telnet",       hint: nil),
        PortInfo(port: 53,    service: "DNS",          hint: "Router"),
        PortInfo(port: 80,    service: "HTTP",         hint: nil),
        PortInfo(port: 139,   service: "NetBIOS",      hint: "Windows"),
        PortInfo(port: 443,   service: "HTTPS",        hint: nil),
        PortInfo(port: 445,   service: "SMB",          hint: "Windows"),
        PortInfo(port: 515,   service: "LPD-Druck",    hint: "Drucker"),
        PortInfo(port: 548,   service: "AFP",          hint: "Mac/NAS"),
        PortInfo(port: 631,   service: "IPP-Druck",    hint: "Drucker"),
        PortInfo(port: 1883,  service: "MQTT",         hint: "Smart Home"),
        PortInfo(port: 3689,  service: "DAAP",         hint: "Apple TV"),
        PortInfo(port: 5000,  service: "UPnP/NAS",     hint: nil),
        PortInfo(port: 5009,  service: "AirPort-Admin", hint: "Router"),
        PortInfo(port: 5060,  service: "SIP",          hint: "Telefon"),
        PortInfo(port: 5900,  service: "VNC",          hint: nil),
        PortInfo(port: 7000,  service: "AirPlay",      hint: "Apple TV"),
        PortInfo(port: 8009,  service: "Chromecast",   hint: "Chromecast"),
        PortInfo(port: 8080,  service: "HTTP-Alt",     hint: nil),
        PortInfo(port: 8123,  service: "Home Assistant", hint: "Smart Home"),
        PortInfo(port: 8443,  service: "HTTPS-Alt",    hint: nil),
        PortInfo(port: 9100,  service: "Rohdruck",     hint: "Drucker"),
        PortInfo(port: 32400, service: "Plex",         hint: "Medienserver"),
        PortInfo(port: 62078, service: "iOS-Sync",     hint: "iPhone/iPad")
    ]

    static func service(for port: UInt16) -> String? {
        wellKnown.first { $0.port == port }?.service
    }

    /// Prüft eine Portliste auf einem Host; gibt die offenen Ports zurück.
    static func scan(ip: UInt32, ports: [UInt16] = wellKnown.map(\.port), timeout: TimeInterval = 0.6) -> [UInt16] {
        var open: [UInt16] = []
        let lock = NSLock()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "netzblick.ports", attributes: .concurrent)
        let limiter = DispatchSemaphore(value: 12)

        for port in ports {
            group.enter()
            limiter.wait()
            queue.async {
                defer { limiter.signal(); group.leave() }
                if probe(ip: ip, port: port, timeout: timeout) {
                    lock.lock(); open.append(port); lock.unlock()
                }
            }
        }
        group.wait()
        return open.sorted()
    }

    /// Nicht blockierender TCP-Verbindungsversuch mit Zeitlimit.
    static func probe(ip: UInt32, port: UInt16, timeout: TimeInterval) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = ip.bigEndian

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(descriptor, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, Int32(timeout * 1000)) > 0 else { return false }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
        return socketError == 0
    }
}
