//
//  SunshineHTTPClient.swift
//  ChloroFrame
//
//  Created by Aman Bhardwaj on 6/8/26.
//

import Foundation
import AppKit
import Security
import CryptoKit
import CommonCrypto

// MARK: - Models

struct ServerInfo {
    let hostname: String
    let gpuType: String
    let serverUniqueId: String
    let pairStatus: Int
    let codecModeSupport: Int

    var isPaired: Bool { pairStatus == 1 }
}

struct SunshineApp: Identifiable {
    let id: Int
    let title: String
    let isHDRSupported: Bool
}

// MARK: - Errors

enum SunshineError: LocalizedError {
    case unreachable
    case httpError(Int)
    case invalidResponse(String)
    case cryptoFailed(String)
    case pinMismatch
    case pairingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreachable:              return "Cannot reach the host — check the address and port"
        case .httpError(let c):         return "Server returned HTTP \(c)"
        case .invalidResponse(let m):   return "Unexpected server response: \(m)"
        case .cryptoFailed(let m):      return "Crypto error: \(m)"
        case .pinMismatch:              return "Wrong PIN — check the number shown on your Sunshine server"
        case .pairingFailed(let m):     return "Pairing failed: \(m)"
        }
    }
}

// MARK: - Client

@MainActor
final class SunshineHTTPClient: NSObject {

    let host: Host

    private let uniqueDeviceId: String
    private var serverCertDER: Data?
    private var httpsPort: UInt16 = 47984
    private var urlSession: URLSession!
    // Phase 1 of pairing blocks on the server until the user enters the PIN in
    // Sunshine's web UI. timeoutIntervalForRequest kills the connection after N
    // seconds of no received data — so Phase 1 needs its own session with a much
    // longer inactivity timeout.
    private var pairingSession: URLSession!

    // Cached SecIdentity for mTLS. Written on MainActor (pair/init), read on URLSession
    // delegate queue — nonisolated(unsafe) is safe because writes always precede reads.
    nonisolated(unsafe) private var _cachedIdentity: SecIdentity?

    init(host: Host) {
        self.host = host

        let idKey = "chloroframe.uniqueid"
        if let saved = UserDefaults.standard.string(forKey: idKey) {
            uniqueDeviceId = saved
        } else {
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(id, forKey: idKey)
            uniqueDeviceId = id
        }

        super.init()

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let pairConfig = URLSessionConfiguration.ephemeral
        pairConfig.timeoutIntervalForRequest = 300  // 5 min inactivity — user needs time to open Sunshine web UI
        pairConfig.timeoutIntervalForResource = 600
        pairingSession = URLSession(configuration: pairConfig, delegate: self, delegateQueue: nil)

        // Pre-load identity on init so HTTPS calls work without needing pair() first.
        loadAndCacheIdentity()
    }

    // MARK: - Public API

    func fetchServerInfo() async throws -> ServerInfo {
        AppLogger.shared.newSession(host: host.address)
        let data = try await get("serverinfo")
        if let portStr = xmlValue(data, "HttpsPort"), let port = UInt16(portStr) {
            httpsPort = port
        }
        let info = try parseServerInfo(data)
        AppLogger.shared.log("hostname=\(info.hostname) gpu=\(info.gpuType) paired=\(info.isPaired) codecModes=\(info.codecModeSupport)", "HTTP", "serverinfo")
        return info
    }

    func isPaired() -> Bool {
        UserDefaults.standard.bool(forKey: pairedKey)
    }

    func pair(pin: String) async throws {
        let (certDER, certSig, privateKey) = try loadOrCreateIdentity()
        // Sunshine's server expects PEM (not DER) for the client cert.
        // crypto::x509() calls PEM_read_bio_X509; sending DER fails at phase 4.
        let certPEM = derToPEM(certDER)

        // ── Phase 1: exchange certificates ──────────────────────────────────────
        AppLogger.shared.log("── phase 1: getservercert (blocks until PIN entered in Sunshine UI) ──", "PAIR", "phase1")
        let salt = randomBytes(16)
        let p1 = try await pairGet("pair", params: [
            "devicename": "roth",
            "updateState": "1",
            "phrase":      "getservercert",
            "salt":        salt.hexString,
            "clientcert":  certPEM.hexString,
        ])
        try requirePaired(p1, phase: "phase 1")
        AppLogger.shared.log("phase 1 OK — got server cert (\(xmlValue(p1, "plaincert")?.count ?? 0) hex chars)", "PAIR", "phase1")
        guard let serverCertHex = xmlValue(p1, "plaincert"),
              let serverCertPEM = Data(hexString: serverCertHex),
              !serverCertPEM.isEmpty else {
            throw SunshineError.invalidResponse("missing plaincert in phase 1")
        }
        // Server sends its cert as PEM. Extract DER for SecKey operations.
        guard let srvDER = pemToDER(serverCertPEM) else {
            throw SunshineError.invalidResponse("could not decode server certificate")
        }
        serverCertDER = srvDER

        // ── Phase 2: client challenge ────────────────────────────────────────────
        AppLogger.shared.log("── phase 2: client challenge ──", "PAIR", "phase2")
        let aesKey         = Data(SHA256.hash(data: salt + Data(pin.utf8)).prefix(16))
        let randomChallenge = randomBytes(16)
        let encChallenge    = try aesECBEncrypt(randomChallenge, key: aesKey)

        let p2 = try await pairGet("pair", params: [
            "devicename":      "roth",
            "updateState":     "1",
            "clientchallenge": encChallenge.hexString,
        ])
        try requirePaired(p2, phase: "phase 2")
        AppLogger.shared.log("phase 2 OK — got challengeresponse", "PAIR", "phase2")
        guard let challengeRespHex = xmlValue(p2, "challengeresponse"),
              let challengeRespEnc = Data(hexString: challengeRespHex) else {
            throw SunshineError.invalidResponse("missing challengeresponse in phase 2")
        }
        let challengeRespData = try aesECBDecrypt(challengeRespEnc, key: aesKey)
        // Layout: [0:32] = SHA-256(randomChallenge + srvCertSig + srvSecret)
        //         [32:48] = serverChallenge (16 bytes)
        guard challengeRespData.count >= 48 else {
            throw SunshineError.invalidResponse("challengeresponse too short (\(challengeRespData.count) bytes)")
        }
        let serverResponse  = Data(challengeRespData.prefix(32))
        let serverChallenge = Data(challengeRespData.dropFirst(32).prefix(16))

        // ── Phase 3: send our challenge response ─────────────────────────────────
        AppLogger.shared.log("── phase 3: server challenge response ──", "PAIR", "phase3")
        let clientSecret = randomBytes(16)
        let srvCertSig   = try certSignatureBytes(srvDER)

        // SHA-256(serverChallenge + clientCertSignature + clientSecret)
        // Uses OUR cert signature — server verifies this against the stored clientcert.
        var challengePayload = Data()
        challengePayload.append(serverChallenge)
        challengePayload.append(certSig)    // our cert's own RSA signature field
        challengePayload.append(clientSecret)
        let payloadHash   = Data(SHA256.hash(data: challengePayload))   // already 32 bytes
        let encPayloadHash = try aesECBEncrypt(payloadHash, key: aesKey)

        let p3 = try await pairGet("pair", params: [
            "devicename":         "roth",
            "updateState":        "1",
            "serverchallengeresp": encPayloadHash.hexString,
        ])
        try requirePaired(p3, phase: "phase 3")
        AppLogger.shared.log("phase 3 OK — got pairingsecret", "PAIR", "phase3")
        guard let pairingSecretHex = xmlValue(p3, "pairingsecret"),
              let pairingSecret = Data(hexString: pairingSecretHex),
              pairingSecret.count > 16 else {
            throw SunshineError.invalidResponse("missing/invalid pairingsecret in phase 3")
        }
        let serverSecret    = Data(pairingSecret.prefix(16))
        let serverSignature = Data(pairingSecret.dropFirst(16))

        // Verify server is authentic: it signed serverSecret with its private key
        try verifyServerSignature(data: serverSecret, signature: serverSignature, certDER: srvDER)

        // Verify the PIN was correct: server computed SHA-256(randomChallenge + srvCertSig + srvSecret)
        // and we should be able to reproduce it now that we have srvSecret.
        var expectedData = Data()
        expectedData.append(randomChallenge)
        expectedData.append(srvCertSig)
        expectedData.append(serverSecret)
        guard Data(SHA256.hash(data: expectedData)) == serverResponse else {
            throw SunshineError.pinMismatch
        }

        AppLogger.shared.log("server signature verified ✓  PIN hash verified ✓", "PAIR", "phase3")
        // ── Phase 4: client pairing secret ──────────────────────────────────────
        AppLogger.shared.log("── phase 4: client pairing secret ──", "PAIR", "phase4")
        var cfErr: Unmanaged<CFError>?
        guard let clientSig = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            clientSecret as CFData,
            &cfErr
        ) as Data? else {
            throw cfErr!.takeRetainedValue()
        }

        let p4 = try await pairGet("pair", params: [
            "devicename":         "roth",
            "updateState":        "1",
            "clientpairingsecret": (clientSecret + clientSig).hexString,
        ])
        try requirePaired(p4, phase: "phase 4")
        AppLogger.shared.log("phase 4 OK", "PAIR", "phase4")

        // ── Phase 5: pairchallenge over HTTPS ────────────────────────────────────
        AppLogger.shared.log("── phase 5: pairchallenge (HTTPS + mTLS) ──", "PAIR", "phase5")
        let p5 = try await pairGetHTTPS("pair", params: [
            "devicename":  "roth",
            "updateState": "1",
            "phrase":      "pairchallenge",
        ])
        try requirePaired(p5, phase: "phase 5")
        AppLogger.shared.log("phase 5 OK — pairing complete ✓", "PAIR", "phase5")

        UserDefaults.standard.set(true, forKey: pairedKey)
        // Reload so subsequent getHTTPS calls can present the cert we just paired with.
        loadAndCacheIdentity()
    }

    func fetchAppList() async throws -> [SunshineApp] {
        AppLogger.shared.log("fetching app list over HTTPS", "HTTP", "applist")
        let data = try await getHTTPS("applist")
        let apps = try parseAppList(data)
        AppLogger.shared.log("parsed \(apps.count) apps: \(apps.map(\.title).joined(separator: ", "))", "HTTP", "applist")
        return apps
    }

    func fetchBoxArt(id: Int) async -> NSImage? {
        guard let data = try? await getHTTPS("appasset", params: [
            "appid":     String(id),
            "AssetType": "2",
            "AssetIdx":  "0",
        ]) else { return nil }
        return NSImage(data: data)
    }

    struct LaunchResult {
        let sessionUrl: String      // rtsp://host:port
        let rikey: Data             // 16-byte GCM key for the stream
        let rikeyid: Int32          // key ID (used to build RTP IV)
    }

    /// Launch an app and return the RTSP session URL + encryption key.
    func launchApp(id: Int, display: DisplayConfig, hdrMode: Bool = false) async throws -> LaunchResult {
        let rikey   = randomBytes(16)
        let rikeyid = Int32.random(in: Int32.min...Int32.max)
        AppLogger.shared.log("appid=\(id) mode=\(display.width)x\(display.height)x\(display.fps) hdrMode=\(hdrMode ? 1 : 0) rikeyid=\(rikeyid) rikey=\(rikey.hexString.prefix(8))…", "HTTP", "launch")
        let data    = try await getHTTPS("launch", params: [
            "appid":              String(id),
            "mode":               "\(display.width)x\(display.height)x\(display.fps)",
            "sops":               "1",
            "localAudioPlayMode": "0",
            "rikey":              rikey.hexString,
            "rikeyid":            String(rikeyid),
            "hdrMode":            hdrMode ? "1" : "0",
        ])
        guard let sessionUrl = xmlValue(data, "sessionUrl0") else {
            let msg = xmlAttr(data, "status_message") ?? "no sessionUrl0"
            AppLogger.shared.log("FAILED — \(msg)", "HTTP", "launch")
            throw SunshineError.invalidResponse(msg)
        }
        AppLogger.shared.log("sessionUrl=\(sessionUrl)", "HTTP", "launch")
        return LaunchResult(sessionUrl: sessionUrl, rikey: rikey, rikeyid: rikeyid)
    }

    /// Tell Sunshine to stop any currently-running session for this app.
    /// Always call before launchApp so Sunshine starts a truly fresh session with the new rikey.
    /// If no session is active the server returns an error — we ignore it.
    func cancelApp(id: Int) async {
        _ = try? await getHTTPS("cancel", params: ["appid": String(id)])
        AppLogger.shared.log("appid=\(id) cancel sent", "HTTP", "cancel")
    }

    func unpair() {
        _cachedIdentity = nil
        UserDefaults.standard.removeObject(forKey: pairedKey)
        UserDefaults.standard.removeObject(forKey: "chloroframe.clientcert")
        UserDefaults.standard.removeObject(forKey: "chloroframe.clientcertsig")
        UserDefaults.standard.removeObject(forKey: "chloroframe.clientprivkey")
        // Best-effort cleanup of any Keychain entries from previous code versions.
        SecItemDelete([kSecClass as String: kSecClassKey,
                       kSecAttrApplicationTag as String: kKeyTag] as CFDictionary)
        SecItemDelete([kSecClass as String: kSecClassCertificate,
                       kSecAttrLabel as String: kCertLabel] as CFDictionary)
    }

    // MARK: - HTTP

    // All pre-pairing API calls (serverinfo, pair phases 1-4) use plain HTTP on the
    // configured port (47989). mTLS is not needed and would fail before pairing.
    private func get(_ path: String, params: [String: String] = [:]) async throws -> Data {
        var comps        = URLComponents()
        comps.scheme     = "http"
        comps.host       = host.address
        comps.port       = Int(host.port)
        comps.path       = "/\(path)"
        comps.queryItems = [URLQueryItem(name: "uniqueid", value: uniqueDeviceId)]
            + params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw SunshineError.unreachable }
        AppLogger.shared.log("GET \(url.absoluteString)", "HTTP", path)
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw SunshineError.unreachable }
            AppLogger.shared.logBlock("← \(http.statusCode) (\(data.count)B)",
                body: String(data: data, encoding: .utf8) ?? "<binary>", "HTTP", path)
            guard http.statusCode == 200 else { throw SunshineError.httpError(http.statusCode) }
            return data
        } catch let e as SunshineError {
            AppLogger.shared.log("ERROR \(e.localizedDescription)", "HTTP", path)
            throw e
        } catch {
            AppLogger.shared.log("ERROR unreachable: \(error.localizedDescription)", "HTTP", path)
            throw SunshineError.unreachable
        }
    }

    // Post-pairing calls (applist, launch) go over HTTPS and require mTLS.
    private func getHTTPS(_ path: String, params: [String: String] = [:]) async throws -> Data {
        if _cachedIdentity == nil { loadAndCacheIdentity() }
        var comps        = URLComponents()
        comps.scheme     = "https"
        comps.host       = host.address
        comps.port       = Int(httpsPort)
        comps.path       = "/\(path)"
        comps.queryItems = [URLQueryItem(name: "uniqueid", value: uniqueDeviceId)]
            + params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw SunshineError.unreachable }
        AppLogger.shared.log("GET (HTTPS mTLS) \(url.absoluteString)  identity=\(_cachedIdentity != nil ? "present" : "MISSING")", "HTTP", path)
        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw SunshineError.unreachable }
            AppLogger.shared.logBlock("← \(http.statusCode) (\(data.count)B)",
                body: String(data: data, encoding: .utf8) ?? "<binary>", "HTTP", path)
            guard http.statusCode == 200 else { throw SunshineError.httpError(http.statusCode) }
            return data
        } catch let e as SunshineError {
            AppLogger.shared.log("ERROR \(e.localizedDescription)", "HTTP", path)
            throw e
        } catch {
            AppLogger.shared.log("ERROR unreachable: \(error.localizedDescription)", "HTTP", path)
            throw SunshineError.unreachable
        }
    }

    // Pairing requests (phases 1-4) use pairingSession (long inactivity timeout for phase 1 block).
    private func pairGet(_ path: String, params: [String: String] = [:]) async throws -> Data {
        var comps        = URLComponents()
        comps.scheme     = "http"
        comps.host       = host.address
        comps.port       = Int(host.port)
        comps.path       = "/\(path)"
        comps.queryItems = [URLQueryItem(name: "uniqueid", value: uniqueDeviceId)]
            + params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw SunshineError.unreachable }
        AppLogger.shared.log("GET (pair) \(url.absoluteString)", "HTTP", path)
        do {
            let (data, response) = try await pairingSession.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw SunshineError.unreachable }
            AppLogger.shared.logBlock("← \(http.statusCode) (\(data.count)B)",
                body: String(data: data, encoding: .utf8) ?? "<binary>", "HTTP", path)
            guard http.statusCode == 200 else { throw SunshineError.httpError(http.statusCode) }
            return data
        } catch let e as SunshineError {
            AppLogger.shared.log("ERROR \(e.localizedDescription)", "HTTP", path)
            throw e
        } catch {
            AppLogger.shared.log("ERROR unreachable: \(error.localizedDescription)", "HTTP", path)
            throw SunshineError.unreachable
        }
    }

    // Phase 5 (pairchallenge) must go over HTTPS — uses pairingSession for consistency.
    private func pairGetHTTPS(_ path: String, params: [String: String] = [:]) async throws -> Data {
        if _cachedIdentity == nil { loadAndCacheIdentity() }
        var comps        = URLComponents()
        comps.scheme     = "https"
        comps.host       = host.address
        comps.port       = Int(httpsPort)
        comps.path       = "/\(path)"
        comps.queryItems = [URLQueryItem(name: "uniqueid", value: uniqueDeviceId)]
            + params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { throw SunshineError.unreachable }
        AppLogger.shared.log("GET (pair HTTPS mTLS) \(url.absoluteString)  identity=\(_cachedIdentity != nil ? "present" : "MISSING")", "HTTP", path)
        do {
            let (data, response) = try await pairingSession.data(from: url)
            guard let http = response as? HTTPURLResponse else { throw SunshineError.unreachable }
            AppLogger.shared.logBlock("← \(http.statusCode) (\(data.count)B)",
                body: String(data: data, encoding: .utf8) ?? "<binary>", "HTTP", path)
            guard http.statusCode == 200 else { throw SunshineError.httpError(http.statusCode) }
            return data
        } catch let e as SunshineError {
            AppLogger.shared.log("ERROR \(e.localizedDescription)", "HTTP", path)
            throw e
        } catch {
            AppLogger.shared.log("ERROR unreachable: \(error.localizedDescription)", "HTTP", path)
            throw SunshineError.unreachable
        }
    }

    // Check root paired flag; throw with the server's status_message if paired=0 or status_code!=200.
    // Apollo returns HTTP 200 with XML status_code="401" when mTLS cert verification fails —
    // those responses have no <paired> element, so we must check the attribute too.
    private func requirePaired(_ data: Data, phase: String) throws {
        if let code = xmlAttr(data, "status_code"), code != "200" {
            let msg = xmlAttr(data, "status_message") ?? "server rejected (code \(code))"
            throw SunshineError.pairingFailed("\(phase): \(msg)")
        }
        guard xmlValue(data, "paired") != "0" else {
            let msg = xmlAttr(data, "status_message") ?? "rejected by server"
            throw SunshineError.pairingFailed("\(phase): \(msg)")
        }
    }

    // MARK: - Certificate helpers

    // Wrap DER bytes in PEM (base64 + headers). Sunshine's server parses clientcert
    // with PEM_read_bio_X509, so we must send PEM not raw DER.
    private func derToPEM(_ der: Data) -> Data {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n".utf8)
    }

    // Strip PEM headers and base64-decode to get raw DER bytes.
    private func pemToDER(_ pem: Data) -> Data? {
        guard let str = String(data: pem, encoding: .utf8) else { return nil }
        let b64 = str.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        return Data(base64Encoded: b64)
    }

    // Extract the raw RSA signature bytes from an X.509 DER cert.
    // DER structure: SEQUENCE { SEQUENCE(TBSCert), SEQUENCE(sigAlg), BIT_STRING(sig) }
    // The BIT_STRING content starts with an "unused bits" byte (always 0x00 for RSA).
    private func certSignatureBytes(_ der: Data) throws -> Data {
        var pos = 0
        func readByte() throws -> UInt8 {
            guard pos < der.count else { throw SunshineError.cryptoFailed("DER truncated") }
            defer { pos += 1 }
            return der[pos]
        }
        func readLength() throws -> Int {
            let first = Int(try readByte())
            if first < 0x80 { return first }
            let count = first & 0x7F
            var len = 0
            for _ in 0..<count { len = len << 8 | Int(try readByte()) }
            return len
        }
        func skipElement() throws {
            _ = try readByte()          // tag
            let len = try readLength()
            guard pos + len <= der.count else { throw SunshineError.cryptoFailed("DER element overrun") }
            pos += len
        }

        guard try readByte() == 0x30 else { throw SunshineError.cryptoFailed("cert: outer SEQUENCE expected") }
        _ = try readLength()
        try skipElement()               // TBSCertificate
        try skipElement()               // signatureAlgorithm
        guard try readByte() == 0x03 else { throw SunshineError.cryptoFailed("cert: BIT STRING expected") }
        let sigLen = try readLength()
        guard try readByte() == 0x00 else { throw SunshineError.cryptoFailed("cert: non-zero unused bits") }
        guard pos + sigLen - 1 <= der.count else { throw SunshineError.cryptoFailed("cert: sig overrun") }
        return der[pos..<pos + sigLen - 1]
    }

    // Verify that the server signed `data` with the private key matching its cert.
    // Detects MITM — server can't produce a valid sig without its private key.
    private func verifyServerSignature(data: Data, signature: Data, certDER: Data) throws {
        guard let cert   = SecCertificateCreateWithData(nil, certDER as CFData),
              let pubKey = SecCertificateCopyKey(cert) else {
            throw SunshineError.cryptoFailed("could not extract server public key")
        }
        var err: Unmanaged<CFError>?
        guard SecKeyVerifySignature(pubKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    data as CFData, signature as CFData, &err) else {
            throw SunshineError.pairingFailed("server signature invalid — possible MITM")
        }
    }

    private var pairedKey: String { "chloroframe.paired.\(host.id)" }

    // MARK: - XML

    private func xmlValue(_ data: Data, _ tag: String) -> String? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        guard let open  = xml.range(of: "<\(tag)>", options: .caseInsensitive),
              let close = xml.range(of: "</\(tag)>", options: .caseInsensitive) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound])
    }

    // Parse an attribute value from the root element, e.g. status_message="..."
    private func xmlAttr(_ data: Data, _ attr: String) -> String? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        let needle = "\(attr)=\""
        guard let open = xml.range(of: needle) else { return nil }
        let rest = xml[open.upperBound...]
        guard let closeIdx = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<closeIdx])
    }

    private func parseServerInfo(_ data: Data) throws -> ServerInfo {
        guard let hostname = xmlValue(data, "hostname") else {
            throw SunshineError.invalidResponse("missing <hostname>")
        }
        return ServerInfo(
            hostname:         hostname,
            gpuType:          xmlValue(data, "gputype") ?? "Unknown GPU",
            serverUniqueId:   xmlValue(data, "uniqueid") ?? "",
            pairStatus:       Int(xmlValue(data, "PairStatus") ?? "0") ?? 0,
            codecModeSupport: Int(xmlValue(data, "ServerCodecModeSupport") ?? "0") ?? 0
        )
    }

    private func parseAppList(_ data: Data) throws -> [SunshineApp] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        var apps: [SunshineApp] = []
        var search = xml.startIndex..<xml.endIndex
        while let open  = xml.range(of: "<App>",  range: search),
              let close = xml.range(of: "</App>", range: open.upperBound..<xml.endIndex) {
            let block = Data(xml[open.lowerBound..<close.upperBound].utf8)
            if let idStr = xmlValue(block, "ID"), let id = Int(idStr),
               let title = xmlValue(block, "AppTitle") {
                apps.append(SunshineApp(
                    id:             id,
                    title:          title,
                    isHDRSupported: xmlValue(block, "IsHdrSupported") == "1"
                ))
            }
            search = close.upperBound..<xml.endIndex
        }
        return apps.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }
}

// MARK: - URLSessionDelegate

extension SunshineHTTPClient: URLSessionDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {

        case NSURLAuthenticationMethodServerTrust:
            // Accept self-signed server certs (Sunshine generates its own CA).
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))

        case NSURLAuthenticationMethodClientCertificate:
            // Sunshine's HTTPS server requires mutual TLS — present our client identity.
            if let identity = storedClientIdentity() {
                completionHandler(.useCredential,
                    URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // Returns the cached identity loaded by loadAndCacheIdentity(). Called from
    // URLSession's internal queue — reads _cachedIdentity which is nonisolated(unsafe).
    nonisolated private func storedClientIdentity() -> SecIdentity? {
        return _cachedIdentity
    }
}

// MARK: - Client Identity

private let kCertLabel = "ChloroFrame Client"
private let kKeyTag    = Data("com.chloroframe.pairing.key".utf8)

extension SunshineHTTPClient {

    private func loadOrCreateIdentity() throws -> (certDER: Data, certSig: Data, privateKey: SecKey) {
        let result = try tryLoadIdentity() ?? generateAndStoreIdentity()
        cacheIdentity(certDER: result.certDER, privateKey: result.privateKey)
        return result
    }

    // Moonlight-Qt pattern: cert + key are stored in UserDefaults (like QSettings) and
    // assembled into a SecIdentity in-memory via SecIdentityCreate — no OS Keychain needed.
    // SecIdentityCreate is a macOS-only API that creates an identity without Keychain backing,
    // equivalent to Qt's QSslConfiguration::setLocalCertificate() + setPrivateKey().
    private func loadAndCacheIdentity() {
        guard let certDER    = UserDefaults.standard.data(forKey: "chloroframe.clientcert"),
              let privKeyDER = UserDefaults.standard.data(forKey: "chloroframe.clientprivkey"),
              let privKey    = SecKeyCreateWithData(privKeyDER as CFData, [
                  kSecAttrKeyType:  kSecAttrKeyTypeRSA,
                  kSecAttrKeyClass: kSecAttrKeyClassPrivate,
              ] as CFDictionary, nil)
        else { return }
        cacheIdentity(certDER: certDER, privateKey: privKey)
    }

    private func cacheIdentity(certDER: Data, privateKey: SecKey) {
        guard let cert     = SecCertificateCreateWithData(nil, certDER as CFData),
              let identity = SecIdentityCreate(kCFAllocatorDefault, cert, privateKey)
        else { return }
        _cachedIdentity = identity
    }

    private func tryLoadIdentity() -> (certDER: Data, certSig: Data, privateKey: SecKey)? {
        guard let certDER    = UserDefaults.standard.data(forKey: "chloroframe.clientcert"),
              let certSig    = UserDefaults.standard.data(forKey: "chloroframe.clientcertsig"),
              let privKeyDER = UserDefaults.standard.data(forKey: "chloroframe.clientprivkey")
        else { return nil }
        // Reconstruct from DER so we get an in-memory SecKey, not a SecCDSAKeyRef.
        // Keys loaded from the legacy macOS Keychain come back as CDSA refs that don't
        // support SecKeyCreateSignature with modern algorithms (-50 algid not supported).
        guard let privKey = SecKeyCreateWithData(privKeyDER as CFData, [
            kSecAttrKeyType:  kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
        ] as CFDictionary, nil) else { return nil }
        return (certDER, certSig, privKey)
    }

    private func generateAndStoreIdentity() throws -> (certDER: Data, certSig: Data, privateKey: SecKey) {
        var cfErr: Unmanaged<CFError>?

        // Generate an in-memory RSA key — no Keychain storage needed. The key is exported
        // to PKCS#1 DER and stored in UserDefaults alongside the cert DER. SecIdentityCreate
        // rebuilds the identity on demand without any Keychain involvement.
        guard let privKey = SecKeyCreateRandomKey([
            kSecAttrKeyType:       kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ] as CFDictionary, &cfErr) else { throw cfErr!.takeRetainedValue() }

        guard let privKeyDER = SecKeyCopyExternalRepresentation(privKey, &cfErr) as Data? else {
            throw cfErr?.takeRetainedValue() ?? SunshineError.cryptoFailed("private key export failed")
        }

        guard let pubKey    = SecKeyCopyPublicKey(privKey),
              let pubKeyDER = SecKeyCopyExternalRepresentation(pubKey, &cfErr) as Data? else {
            throw cfErr?.takeRetainedValue() ?? SunshineError.cryptoFailed("public key export failed")
        }

        let (certDER, certSig) = try buildX509Cert(pubKeyDER: pubKeyDER, signingKey: privKey)

        UserDefaults.standard.set(certDER,    forKey: "chloroframe.clientcert")
        UserDefaults.standard.set(certSig,    forKey: "chloroframe.clientcertsig")
        UserDefaults.standard.set(privKeyDER, forKey: "chloroframe.clientprivkey")
        return (certDER, certSig, privKey)   // live ref from generation — modern SecKey, not CDSA
    }

    // Returns (certDER, rawSignatureBytes). We return the signature separately so
    // pairing can use it without re-parsing the DER.
    private func buildX509Cert(pubKeyDER: Data, signingKey: SecKey) throws -> (Data, Data) {
        let rsaOID    = oid([1, 2, 840, 113549, 1, 1, 1])   // rsaEncryption
        let sha256rsa = oid([1, 2, 840, 113549, 1, 1, 11])  // sha256WithRSAEncryption
        let cnOID     = oid([2, 5, 4, 3])                    // id-at-commonName

        let sigAlg = seq(sha256rsa + derNull)
        let name   = seq(set(seq(cnOID + utf8str("NVIDIA GameStream Client"))))
        let spki   = seq(seq(rsaOID + derNull) + bitstr(pubKeyDER))

        let tbs = seq(
            ctxTag(0, integer(Data([0x02]))) +
            integer(Data([0x01])) +
            sigAlg +
            name +
            seq(utctime("260101000000Z") + utctime("460101000000Z")) +
            name +
            spki
        )

        var cfErr: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            signingKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            tbs as CFData,
            &cfErr
        ) as Data? else { throw cfErr!.takeRetainedValue() }

        return (seq(tbs + sigAlg + bitstr(sig)), sig)
    }

    // MARK: Minimal ASN.1 DER encoder

    private func derLen(_ n: Int) -> Data {
        if n < 0x80  { return Data([UInt8(n)]) }
        if n < 0x100 { return Data([0x81, UInt8(n)]) }
        return Data([0x82, UInt8(n >> 8), UInt8(n & 0xFF)])
    }
    private func tlv(_ tag: UInt8, _ content: Data) -> Data {
        Data([tag]) + derLen(content.count) + content
    }
    private func seq(_ c: Data) -> Data    { tlv(0x30, c) }
    private func set(_ c: Data) -> Data    { tlv(0x31, c) }
    private var  derNull: Data             { Data([0x05, 0x00]) }
    private func integer(_ b: Data) -> Data {
        tlv(0x02, (b.first ?? 0) & 0x80 != 0 ? Data([0x00]) + b : b)
    }
    private func oid(_ components: [UInt]) -> Data {
        var bytes = Data([UInt8(40 * components[0] + components[1])])
        for c in components.dropFirst(2) {
            var v = c
            var octets: [UInt8] = [UInt8(v & 0x7F)]
            v >>= 7
            while v > 0 { octets.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
            bytes += Data(octets.reversed())
        }
        return tlv(0x06, bytes)
    }
    private func utf8str(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }
    private func utctime(_ s: String) -> Data { tlv(0x17, Data(s.utf8)) }
    private func bitstr(_ b: Data) -> Data    { tlv(0x03, Data([0x00]) + b) }
    private func ctxTag(_ tag: UInt8, _ c: Data) -> Data { tlv(0xA0 | tag, c) }
}

// MARK: - Crypto

extension SunshineHTTPClient {

    private func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private func aesECBEncrypt(_ plaintext: Data, key: Data) throws -> Data {
        try aesCrypt(plaintext, key: key, encrypt: true)
    }

    private func aesECBDecrypt(_ ciphertext: Data, key: Data) throws -> Data {
        try aesCrypt(ciphertext, key: key, encrypt: false)
    }

    private func aesCrypt(_ input: Data, key: Data, encrypt: Bool) throws -> Data {
        let bufSize = input.count + kCCBlockSizeAES128
        var output  = Data(count: bufSize)
        var outLen  = 0
        let op      = encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt)

        let status: CCCryptorStatus = key.withUnsafeBytes { kPtr in
            input.withUnsafeBytes { iPtr in
                output.withUnsafeMutableBytes { oPtr in
                    CCCrypt(op,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),
                            kPtr.baseAddress, key.count,
                            nil,
                            iPtr.baseAddress, input.count,
                            oPtr.baseAddress, bufSize,
                            &outLen)
                }
            }
        }
        guard status == kCCSuccess else {
            throw SunshineError.cryptoFailed("AES-ECB returned \(status)")
        }
        return output.prefix(outLen)
    }
}

// MARK: - Data Hex Helpers

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.count / 2)
        var idx  = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            data.append(byte)
            idx = next
        }
        self = data
    }
}
