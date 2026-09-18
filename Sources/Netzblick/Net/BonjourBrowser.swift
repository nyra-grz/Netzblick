import Foundation
import Network

/// Ein per mDNS/Bonjour gefundener Dienst.
struct BonjourService: Hashable {
    let name: String
    let type: String
    var txt: [String: String]
    var ip: UInt32?

    /// Kennung, die manche Apple-Dienste im TXT-Record mitschicken.
    ///
    /// Sieht aus wie eine MAC-Adresse, ist aber keine: `rpBA` und `deviceid`
    /// rotieren regelmäßig. Taugt zur Anzeige, nicht zur Wiedererkennung –
    /// als Geräteidentität zählt allein die MAC aus der ARP-Tabelle.
    var advertisedIdentifier: String? {
        for key in ["rpBA", "deviceid", "mac", "macaddress"] {
            if let raw = txt[key], let value = SystemNet.normalizeMAC(raw.lowercased()) { return value }
        }
        return nil
    }

    /// Modellkennung wie `MacBookPro18,3` oder `AppleTV14,1`.
    var model: String? { txt["model"] ?? txt["am"] ?? txt["md"] }
}

/// Durchsucht das lokale Netz nach Bonjour-Diensten und löst sie zu IP-Adressen auf.
final class BonjourBrowser {

    /// Dienstarten, die in Heimnetzen etwas über Gerät und Hersteller verraten.
    static let serviceTypes = [
        "_device-info._tcp", "_companion-link._tcp", "_airplay._tcp", "_raop._tcp",
        "_homekit._tcp", "_hap._tcp", "_googlecast._tcp", "_spotify-connect._tcp",
        "_smb._tcp", "_afpovertcp._tcp", "_ssh._tcp", "_sftp-ssh._tcp", "_rfb._tcp",
        "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp", "_scanner._tcp",
        "_http._tcp", "_https._tcp", "_workstation._tcp", "_daap._tcp", "_touch-able._tcp",
        "_sleep-proxy._udp", "_apple-mobdev2._tcp", "_nvstream._tcp", "_androidtvremote2._tcp",
        "_miio._udp", "_hue._tcp", "_ewelink._tcp", "_matter._tcp", "_matterc._udp",
        "_esphomelib._tcp", "_home-assistant._tcp", "_plexmediasvr._tcp", "_nas._tcp"
    ]

    private var browsers: [NWBrowser] = []
    private let queue = DispatchQueue(label: "netzblick.bonjour")
    private let lock = NSLock()
    private var discovered: [String: BonjourService] = [:]

    /// Sammelt `duration` Sekunden lang Dienste ein und löst sie anschließend auf.
    func browse(duration: TimeInterval) -> [BonjourService] {
        start()
        Thread.sleep(forTimeInterval: duration)
        stop()

        lock.lock()
        var services = Array(discovered.values)
        lock.unlock()

        resolveAddresses(for: &services)
        return services
    }

    private func start() {
        for type in Self.serviceTypes {
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    guard case let .service(name, serviceType, _, _) = result.endpoint else { continue }
                    var txt: [String: String] = [:]
                    if case let .bonjour(record) = result.metadata {
                        for (key, value) in record.dictionary { txt[key.lowercased()] = value }
                        // Originalschreibweise für Schlüssel wie rpBA beibehalten.
                        for (key, value) in record.dictionary { txt[key] = value }
                    }
                    let service = BonjourService(name: name, type: serviceType, txt: txt, ip: nil)
                    self.lock.lock()
                    let key = "\(name)|\(serviceType)"
                    if var existing = self.discovered[key] {
                        existing.txt.merge(txt) { current, _ in current }
                        self.discovered[key] = existing
                    } else {
                        self.discovered[key] = service
                    }
                    self.lock.unlock()
                }
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    private func stop() {
        for browser in browsers { browser.cancel() }
        browsers.removeAll()
    }

    /// Löst Dienstnamen über mDNS zu IP-Adressen auf.
    ///
    /// Die Auflösung läuft bewusst über UDP-Parameter: Dabei genügt der reine
    /// Namenslookup, es wird kein TCP-Handshake erwartet, den viele Geräte
    /// ohnehin ablehnen würden.
    private func resolveAddresses(for services: inout [BonjourService]) {
        let group = DispatchGroup()
        let limiter = DispatchSemaphore(value: 8)
        let resolvedLock = NSLock()
        var resolved: [String: UInt32] = [:]

        for service in services {
            let key = "\(service.name)|\(service.type)"
            group.enter()
            limiter.wait()
            let endpoint = NWEndpoint.service(name: service.name, type: service.type, domain: "local.", interface: nil)
            let connection = NWConnection(to: endpoint, using: .udp)
            var finished = false
            let finish: (UInt32?) -> Void = { ip in
                resolvedLock.lock()
                defer { resolvedLock.unlock() }
                guard !finished else { return }
                finished = true
                if let ip { resolved[key] = ip }
                connection.cancel()
                limiter.signal()
                group.leave()
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else { finish(nil); return }
                    if case let .ipv4(address) = host {
                        let value = address.rawValue.withUnsafeBytes { $0.load(as: UInt32.self) }
                        finish(UInt32(bigEndian: value))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
        _ = group.wait(timeout: .now() + 12)

        resolvedLock.lock()
        let snapshot = resolved
        resolvedLock.unlock()
        for index in services.indices {
            let key = "\(services[index].name)|\(services[index].type)"
            services[index].ip = snapshot[key]
        }
    }
}
