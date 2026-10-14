//
//  PyroWaveUdpProbeHTTP.swift
//  ChloroFrame
//
//  HTTPS half of the PyroWave UDP network test (D7b). The host answers /pyrowave-udp-probe with
//  its response headers first (X-PyroWave-Udp-Port) and keeps the XML body open until the
//  measured transfer ends, so the headers have to be surfaced before the body completes. That
//  needs a data delegate, which the shared async `URLSession.data(for:)` path cannot give.
//

import Foundation

/// A value delivered once, awaited by one task. Either order (fulfil then wait, wait then
/// fulfil) works.
nonisolated final class PyroWaveOneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var waiter: CheckedContinuation<T, Never>?

    func fulfill(_ v: T) {
        lock.lock()
        if value != nil { lock.unlock(); return }
        value = v
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: v)
    }

    func wait() async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            lock.lock()
            if let v = value { lock.unlock(); c.resume(returning: v) }
            else { waiter = c; lock.unlock() }
        }
    }
}

nonisolated final class PyroWaveUdpProbeHTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum Headers: Sendable, Equatable {
        /// 200 with the host's UDP port.
        case ready(udpPort: Int)
        /// 200 without `X-PyroWave-Udp-Port` (a host that ignored `handshake=1`).
        case missingPort
        /// Any other status. The body, once complete, carries the host's reason.
        case rejected(status: Int)
        case failed(String)
    }

    enum Completion: Sendable { case body(Data), failed(String) }

    let headers = PyroWaveOneShot<Headers>()
    let completion = PyroWaveOneShot<Completion>()
    private let identity: SecIdentity?
    private let lock = NSLock()
    private var body = Data()

    init(identity: SecIdentity?) {
        self.identity = identity
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        case NSURLAuthenticationMethodClientCertificate:
            if let identity {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 200 {
                if let value = http.value(forHTTPHeaderField: "X-PyroWave-Udp-Port"), let port = Int(value),
                   port >= 1024, port <= 65535 {
                    headers.fulfill(.ready(udpPort: port))
                } else {
                    headers.fulfill(.missingPort)
                }
            } else {
                headers.fulfill(.rejected(status: http.statusCode))
            }
        } else {
            headers.fulfill(.failed("the host did not answer with HTTP"))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); body.append(data); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            headers.fulfill(.failed(error.localizedDescription))   // no-op when headers already arrived
            completion.fulfill(.failed(error.localizedDescription))
        } else {
            lock.lock(); let data = body; lock.unlock()
            completion.fulfill(.body(data))
        }
    }
}
