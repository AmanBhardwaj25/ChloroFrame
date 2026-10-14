//
//  HostHdrModeMessage.swift
//  ChloroFrame
//
//  The host's HDR mode control message (type 0x010e, moonlight-common-c IDX_HDR_INFO, vibeshine
//  stream.cpp send_hdr_mode). PyroWave carries no color information in its bitstream, so this
//  message is how the client learns whether the 10-bit stream is HDR10 (BT.2020 PQ) or 10-bit
//  SDR: the host sends PQ only when the captured display is HDR and 10-bit SDR was not forced.
//  Pure parsing, unit tested. See design/pyrowave-implementation-plan.md D9.
//

import Foundation
import CryptoKit

nonisolated enum HostHdrModeMessage {

    static let controlType: UInt16 = 0x010e

    /// Parses one reliable ENet payload from the host control stream. Returns the `enabled`
    /// flag when the payload is an HDR mode message, nil for any other message or on any
    /// parse or authentication failure.
    ///
    /// With `key` set the payload is the encrypted form:
    ///   LE16 0x0001, LE16 length, LE32 seq, 16 byte GCM tag, ciphertext
    /// where `length` counts seq + tag + ciphertext, and the nonce is LE32(seq) followed by
    /// six zero bytes and 'H', 'C' (host originated, control stream). The plaintext is
    ///   LE16 type, LE16 payloadLength, then `enabled` (1 byte) and the display metadata.
    /// Without a key the payload is that plaintext directly.
    static func parse(payload: [UInt8], key: SymmetricKey?) -> Bool? {
        guard let key else { return enabledFlag(plaintext: payload) }
        guard payload.count >= 8, payload[0] == 0x01, payload[1] == 0x00 else {
            return enabledFlag(plaintext: payload)
        }
        let length = Int(payload[2]) | Int(payload[3]) << 8
        // seq (4) + tag (16) + at least one ciphertext byte.
        guard length >= 21, payload.count >= 4 + length else { return nil }
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = payload[4]; nonce[1] = payload[5]; nonce[2] = payload[6]; nonce[3] = payload[7]
        nonce[10] = 0x48   // 'H'
        nonce[11] = 0x43   // 'C'
        let tag = Data(payload[8..<24])
        let cipher = Data(payload[24..<(4 + length)])
        guard let gcmNonce = try? AES.GCM.Nonce(data: Data(nonce)),
              let box = try? AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: cipher, tag: tag),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return enabledFlag(plaintext: [UInt8](plain))
    }

    private static func enabledFlag(plaintext p: [UInt8]) -> Bool? {
        guard p.count >= 5 else { return nil }
        let type = UInt16(p[0]) | UInt16(p[1]) << 8
        guard type == controlType else { return nil }
        return p[4] != 0
    }

    /// Test helper: builds the encrypted wire form the host sends (inverse of `parse`).
    static func encryptedPayload(enabled: Bool, seq: UInt32, key: SymmetricKey,
                                 metadataBytes: Int = 28) -> [UInt8] {
        var plain: [UInt8] = [0x0e, 0x01]
        let body = 1 + metadataBytes
        plain += [UInt8(body & 0xFF), UInt8(body >> 8)]
        plain.append(enabled ? 1 : 0)
        plain += [UInt8](repeating: 0, count: metadataBytes)
        var nonce = [UInt8](repeating: 0, count: 12)
        nonce[0] = UInt8(seq & 0xFF); nonce[1] = UInt8((seq >> 8) & 0xFF)
        nonce[2] = UInt8((seq >> 16) & 0xFF); nonce[3] = UInt8((seq >> 24) & 0xFF)
        nonce[10] = 0x48; nonce[11] = 0x43
        guard let gcmNonce = try? AES.GCM.Nonce(data: Data(nonce)),
              let sealed = try? AES.GCM.seal(Data(plain), using: key, nonce: gcmNonce) else { return [] }
        let length = 4 + 16 + sealed.ciphertext.count
        var out: [UInt8] = [0x01, 0x00, UInt8(length & 0xFF), UInt8(length >> 8)]
        out += [nonce[0], nonce[1], nonce[2], nonce[3]]
        out += Array(sealed.tag)
        out += Array(sealed.ciphertext)
        return out
    }
}
