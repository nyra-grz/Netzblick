import SwiftUI

@main
struct NetzblickApp: App {

    @StateObject private var scanner = Scanner()

    var body: some Scene {
        WindowGroup("Netzblick") {
            ContentView()
                .environmentObject(scanner)
                .frame(minWidth: 960, minHeight: 560)
                // Die Oberfläche ist durchgehend deutsch – Datums- und
                // Zahlenformate sollen dazu passen, auch auf einem
                // englischsprachigen System.
                .environment(\.locale, Locale(identifier: "de_DE"))
        }
        .defaultSize(width: 1400, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Scan") {
                Button(scanner.isScanning ? "Scan stoppen" : "Netzwerk scannen") {
                    scanner.isScanning ? scanner.stopScan() : scanner.startScan()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
