# Netzblick

Nativer macOS-Netzwerkscanner in SwiftUI. Findet alle Geräte im lokalen Netz
und sammelt zu jedem so viele Informationen wie möglich: Name, IP, MAC,
Hersteller, Gerätetyp, offene Dienste und Antwortzeit.

## Starten

Die fertige App liegt in `/Applications/Netzblick.app`.

Neu bauen:

```bash
./build.sh          # Release-Build + signiertes App-Bundle in build/
./build.sh debug    # schnellerer Debug-Build
```

## Wie die Erkennung funktioniert

Ein Scan kombiniert sechs Quellen, weil keine allein reicht:

| Quelle | Liefert | Bemerkung |
|---|---|---|
| **ICMP-Sweep** | Erreichbarkeit, Antwortzeit | Unprivilegierter `SOCK_DGRAM`-ICMP-Socket, kein `sudo` nötig |
| **ARP-Tabelle** | MAC-Adresse | Findet auch Geräte, die Pings ignorieren – jedes gesendete Paket erzwingt eine ARP-Auflösung |
| **Bonjour/mDNS** | Klarnamen, Modellkennung | 36 Diensttypen, u. a. AirPlay, HomeKit, Drucker, Chromecast |
| **SSDP/UPnP** | Hersteller, Modell, Klarname | Wichtigster Kanal für TVs, Router und Windows-Rechner |
| **Reverse-DNS** | Hostname | Im Heimnetz beantwortet ihn meist der Router |
| **NetBIOS (UDP 137)** | Rechnername | Für Windows-PCs und Samba-Server |
| **Web-Banner** | Seitentitel, Server-Header | Router, Drucker, NAS und Kameras verraten ihr Modell im Titel ihrer Weboberfläche |
| **TTL-Fingerprint** | Betriebssystem-Familie | Windows startet die TTL bei 128, Unix-artige Systeme bei 64 – kostet kein extra Paket, die Ping-Antwort enthält den Wert schon |

Der Gerätetyp wird aus offenen Ports, Bonjour-Diensten, Herstellernamen und
der TTL abgeleitet – Port 62078 bedeutet z. B. iPhone/iPad, Port 9100 einen
Drucker, TTL 128 einen Windows-Rechner.

Die drei großen Plattformen sind dabei unterschiedlich gesprächig:

- **iOS** lässt auf jedem iPhone und iPad Port 62078 offen. Eindeutig erkennbar.
- **Windows** stuft fremde Netze als „öffentlich“ ein und blockiert alle
  eingehenden Ports, auch 445 und 139. Verrät sich aber über die TTL 128.
- **Android** hat weder offene Ports noch eine TTL, die es von Linux
  unterscheidet. Bleibt nur das MAC-Präfix – und das ist bei modernen
  Android-Telefonen meist zufällig gewürfelt. Diese Geräte sind schlicht nicht
  als Android identifizierbar; das ist Absicht der Hersteller, keine Lücke der App.

Die Hersteller-Zuordnung nutzt die offiziellen IEEE-Register (MA-L, MA-M, MA-S)
mit 53.514 Einträgen in `Resources/oui.tsv`. Die Datei ist aus den öffentlichen
Registern von <https://standards-oui.ieee.org/> erzeugt und nur gekürzt
(Rechtsformen und Ortszusätze entfernt), damit die Namen in eine Tabellenspalte
passen.

## Geräte benennen

Jedes Gerät lässt sich mit einem eigenen Namen und einer Notiz versehen. Beides
liegt zusammen mit der Historie in
`~/Library/Application Support/Netzblick/devices.json`, das sich außerdem merkt,
wann ein Gerät zuerst und zuletzt gesehen wurde. Einträge, die 90 Tage nicht
mehr aufgetaucht sind und weder Namen noch Notiz tragen, räumt die App selbst
weg.

## Zwei Eigenheiten von macOS 27

**MAC-Adressen nur für signierte Apps.** macOS gibt Link-Layer-Informationen
nicht mehr an beliebige Prozesse heraus: Ein unsigniertes Kommandozeilen-Binary
bekommt eine leere ARP-Tabelle und den Platzhalter `02:00:00:00:00:00`, das
signierte App-Bundle die echten Adressen. Deshalb ist der Ad-hoc-Signaturschritt
in `build.sh` nicht optional. Fehlen die MAC-Adressen trotzdem, weist die App
oben auf die Berechtigung „Lokales Netzwerk" hin.

**SwiftUI braucht Xcode.** `@State` und Co. sind inzwischen Makros. Die Command
Line Tools allein liefern das nötige Plugin nicht, `build.sh` setzt darum
`DEVELOPER_DIR` auf Xcode.

## Wenn keine Namen erscheinen

In verwalteten Netzen – Wohnheim, Mehrparteienhaus, Gäste-WLAN – blockiert der
Access Point den Datenverkehr zwischen den Clients. Dann liefern Bonjour, SSDP,
LLMNR und NetBIOS nichts, und es bleiben Hersteller, Gerätetyp und offene Ports.
Gegengeprüft mit Apples eigenem `dns-sd -B _services._dns-sd._udp local`: Sind
dort nur die eigenen Dienste zu sehen, filtert das Netz Multicast – die App kann
dann nicht mehr finden als sonst jemand.

Damit die Liste trotzdem lesbar bleibt, bekommen namenlose Geräte einen
unterscheidbaren Bezeichner aus Hersteller und MAC-Endung, etwa
`Intel · B9:76:C5` statt achtzig Mal „Unbekanntes Gerät“.

## Zufällige MAC-Adressen

Viele Geräte – vor allem Smartphones – würfeln ihre MAC pro Netzwerk neu. Die
App erkennt das am U/L-Bit und zeigt statt eines Herstellers „zufällige MAC" an.
Solche Geräte lassen sich zwischen zwei Scans nicht zuverlässig wiedererkennen;
die Wiedererkennung stützt sich dann auf die IP-Adresse.

Auch Bonjour-Felder wie `rpBA` oder `deviceid` sehen aus wie MAC-Adressen,
rotieren aber regelmäßig. Sie werden nur als „Bonjour-Kennung" angezeigt und
nie zur Wiedererkennung benutzt.

## Aufbau

```
Sources/Netzblick/
  Net/        SystemNet (Interfaces, Routen, ARP), PingSweeper, PortScanner,
              BonjourBrowser, SSDPDiscovery, NameResolver, VendorDatabase
  Model/      Device (+ Gerätetyp-Erkennung), DeviceStore, Scanner
  Views/      ContentView, NetworkSummaryBar, DeviceDetailView
```
