//
//  TVRemoteInput.swift
//  ChloroFrameTV
//
//  Sends mouse input (relative move, buttons, scroll) to the host for the Siri Remote's
//  trackpad/click mapping. Builds the same Apollo/moonlight-common-c packets the macOS
//  InputHandler uses, on the mouse control channel (0x03), via StreamTransport.sendInput.
//
//  Wire formats (NV_INPUT_HEADER = BE32(size) | LE32(magic), size = bytes after the size field):
//    rel move  0x07          : BE32(8)  | dx BE16 | dy BE16
//    btn down  0x08 / up 0x09 : BE32(5)  | button(1)   (left=1, middle=2, right=3)
//    vscroll   0x0A          : BE32(10) | amt BE16 | amt BE16 | 0,0
//    hscroll   0x55000001    : BE32(6)  | amt BE16
//

import Foundation

@MainActor
final class TVRemoteInput {

    static let leftButton:  UInt8 = 1
    static let rightButton: UInt8 = 3

    private weak var transport: StreamTransport?
    private var heldButtons = Set<UInt8>()
    // Sub-pixel accumulator so slow finger motion isn't lost to integer truncation.
    private var accX: CGFloat = 0
    private var accY: CGFloat = 0

    init(transport: StreamTransport?) { self.transport = transport }

    func moveRelative(dx: CGFloat, dy: CGFloat) {
        accX += dx
        accY += dy
        var ix = Int(accX), iy = Int(accY)
        accX -= CGFloat(ix); accY -= CGFloat(iy)
        guard ix != 0 || iy != 0 else { return }
        // Split into Int16 chunks (matches the macOS sender) so large flicks don't clamp.
        while ix != 0 || iy != 0 {
            let cx = Int16(clamping: ix), cy = Int16(clamping: iy)
            guard cx != 0 || cy != 0 else { break }
            var p = [UInt8]()
            p += be32(8); p += le32(0x0000_0007)
            p += be16(UInt16(bitPattern: cx)); p += be16(UInt16(bitPattern: cy))
            send(p)
            ix -= Int(cx); iy -= Int(cy)
        }
    }

    func mouseDown(_ button: UInt8) {
        heldButtons.insert(button)
        var p = [UInt8](); p += be32(5); p += le32(0x0000_0008); p.append(button)
        send(p)
    }

    func mouseUp(_ button: UInt8) {
        heldButtons.remove(button)
        var p = [UInt8](); p += be32(5); p += le32(0x0000_0009); p.append(button)
        send(p)
    }

    /// A full click (down then up) of the given button.
    func click(_ button: UInt8) {
        mouseDown(button)
        mouseUp(button)
    }

    func scrollVertical(_ amount: Int16) {
        guard amount != 0 else { return }
        var p = [UInt8]()
        p += be32(10); p += le32(0x0000_000A)
        p += be16(UInt16(bitPattern: amount)); p += be16(UInt16(bitPattern: amount)); p += [0x00, 0x00]
        send(p)
    }

    func scrollHorizontal(_ amount: Int16) {
        guard amount != 0 else { return }
        var p = [UInt8]()
        p += be32(6); p += le32(0x5500_0001); p += be16(UInt16(bitPattern: amount))
        send(p)
    }

    /// Release any held button (call on teardown so nothing sticks on the host).
    func releaseAll() {
        for b in heldButtons { mouseUp(b) }
    }

    // MARK: - bytes

    private func send(_ packet: [UInt8]) { transport?.sendInput(packet: packet, channel: 0x03) }
    private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
}
