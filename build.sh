#!/bin/bash
# Baut Netzblick.app aus dem Swift-Paket und signiert sie ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

# Die Command Line Tools allein reichen nicht: SwiftUI braucht das
# Makro-Plugin aus Xcode (@State & Co. sind inzwischen Makros).
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

CONFIG="${1:-release}"
APP="build/Netzblick.app"

echo "▸ Kompiliere ($CONFIG) …"
swift build -c "$CONFIG"

echo "▸ Baue App-Bundle …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Netzblick" "$APP/Contents/MacOS/Netzblick"
cp Resources/oui.tsv "$APP/Contents/Resources/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# NSBonjourServices direkt aus dem Quelltext ableiten, damit Plist und
# Browser nie auseinanderlaufen – ohne den Eintrag blockiert macOS mDNS.
python3 - "$APP/Contents/Info.plist" <<'PY'
import re, sys, plistlib
source = open('Sources/Netzblick/Net/BonjourBrowser.swift').read()
block = re.search(r'serviceTypes = \[(.*?)\]', source, re.S).group(1)
types = re.findall(r'"([^"]+)"', block)
plist = {
    'CFBundleName': 'Netzblick',
    'CFBundleDisplayName': 'Netzblick',
    'CFBundleIdentifier': 'de.timur.netzblick',
    'CFBundleExecutable': 'Netzblick',
    'CFBundleIconFile': 'AppIcon',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '1.0',
    'CFBundleVersion': '1',
    'CFBundleInfoDictionaryVersion': '6.0',
    'LSMinimumSystemVersion': '14.0',
    'LSApplicationCategoryType': 'public.app-category.utilities',
    'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication',
    'NSHumanReadableCopyright': 'Netzblick',
    'NSLocalNetworkUsageDescription':
        'Netzblick durchsucht dein lokales Netzwerk, um alle verbundenen Geräte mit Name, '
        'IP-Adresse, MAC-Adresse und Hersteller aufzulisten.',
    'NSBonjourServices': types,
}
plistlib.dump(plist, open(sys.argv[1], 'wb'))
print(f'  Info.plist mit {len(types)} Bonjour-Diensten')
PY

echo "▸ Signiere …"
codesign --force --sign - --identifier de.timur.netzblick "$APP"
codesign --verify --strict "$APP" && echo "  Signatur ok"

echo "✓ Fertig: $(pwd)/$APP"
