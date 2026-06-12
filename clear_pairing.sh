#!/bin/bash
set -e

BUNDLE_ID="fullstacksandbox.com.ChloroFrame"

echo "Clearing ChloroFrame pairing data..."

# UserDefaults: hosts, paired flags, cert DER, key DER
defaults delete "$BUNDLE_ID" 2>/dev/null \
    && echo "  [ok] UserDefaults cleared" \
    || echo "  [--] UserDefaults already empty"

# Keychain: certificate (kSecClassCertificate, label = "ChloroFrame Client")
security delete-certificate -c "ChloroFrame Client" 2>/dev/null \
    && echo "  [ok] Keychain cert deleted" \
    || echo "  [--] No cert found in Keychain"

# Keychain: private key (kSecClassKey, tag = "com.chloroframe.pairing.key")
# security CLI has no delete-key command, so use the Swift interpreter.
swift - <<'SWIFT' 2>/dev/null \
    && echo "  [ok] Keychain key deleted" \
    || echo "  [--] No key found in Keychain"
import Security
let tag = "com.chloroframe.pairing.key".data(using: .utf8)!
let q: [String: Any] = [
    kSecClass as String:              kSecClassKey,
    kSecAttrApplicationTag as String: tag,
]
let s = SecItemDelete(q as CFDictionary)
exit(s == errSecSuccess || s == errSecItemNotFound ? 0 : 1)
SWIFT

echo "Done. Launch ChloroFrame and pair fresh."
