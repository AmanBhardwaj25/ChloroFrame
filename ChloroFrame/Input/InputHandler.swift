//
//  InputHandler.swift
//  ChloroFrame
//

import AppKit
import QuartzCore

// Translates NSEvent keyboard/mouse input into Apollo NV_INPUT_HEADER packets
// and sends them over the ENet control stream (type 0x0206, channel per input type).
//
// NV_INPUT_HEADER wire format (from moonlight-common-c Input.h / InputStream.c):
//   [BE32(size)]   — byte count of everything that follows (excludes this field itself)
//   [LE32(magic)]  — packet type discriminator
//   [payload]      — type-specific fields (see struct comments below)
//
// Packets are sent PLAINTEXT to sendInput(). The ENet layer (ENetClient.sendControl) handles
// AES-GCM encryption when useReliableUdp=13 / encryptedControlStream is active.
//
// ENet channels: keyboard=0x02, mouse=0x03

@MainActor
final class InputHandler {

    private weak var transport: StreamTransport?
    private var packetsSent = 0

    // Mouse delta accumulator. CGFloat carries the sub-pixel remainder between events so slow
    // motion is not lost to integer truncation. Deltas are flushed immediately on each AppKit
    // mouse event (AppKit already coalesces rapid moves), so no fixed timer delay is added
    // before the packet goes out. All access is on the main thread (AppKit events on the main
    // run loop), so no locking is needed.
    private var pendingDX: CGFloat = 0
    private var pendingDY: CGFloat = 0

    // Tracks currently-held keys and buttons so releaseAll() can send up-events on focus loss.
    private var heldKeys    = Set<Int>()    // Win32 VK codes
    private var heldButtons = Set<UInt8>()  // Apollo button codes (1=left,2=mid,3=right,4=x1,5=x2)

    init(transport: StreamTransport) {
        self.transport = transport
        AppLogger.shared.log("InputHandler init", "input", "init")
    }

    /// Release all held keys and mouse buttons. Call on focus loss, disconnect, or stream stop
    /// so the remote OS doesn't see stuck keys or buttons.
    func releaseAll() {
        pendingDX = 0
        pendingDY = 0
        // Snapshot and clear before iterating — sendRawKey mutates heldKeys (remove),
        // so iterating the live set would trap on the mutation-during-enumeration guard.
        let keys    = heldKeys
        let buttons = heldButtons
        heldKeys.removeAll()
        heldButtons.removeAll()
        for vk in keys    { sendRawKey(vk: vk, modifiers: 0, down: false) }
        for btn in buttons {
            var p = [UInt8]()
            p += be32(5)
            p += le32(0x0000_0009)  // mouseUp
            p.append(btn)
            send(p, channel: 0x03, label: "releaseAll mouseUp btn=\(btn)")
        }
    }

    // MARK: - Unicode text

    // Called by NSTextInputClient.insertText for IME output, emoji, and composed characters.
    // Each Unicode code point is sent as a separate NV_UNICODE_PACKET (magic 0x17) on channel 0x02.
    // Regular key presses use the VK path below; this path is for text the OS has already composed.
    //
    // NV_UNICODE_PACKET:  BE32(4 + cpLen) | LE32(0x17) | UTF-8 bytes of one code point
    func handleText(_ text: String) {
        let utf8 = Array(text.utf8)
        var i = 0
        while i < utf8.count {
            let first = utf8[i]
            let cpLen: Int
            if      first & 0x80 == 0x00 { cpLen = 1 }
            else if first & 0xE0 == 0xC0 { cpLen = 2 }
            else if first & 0xF0 == 0xE0 { cpLen = 3 }
            else if first & 0xF8 == 0xF0 { cpLen = 4 }
            else { break }  // invalid UTF-8 start byte
            guard i + cpLen <= utf8.count else { break }
            var p = [UInt8]()
            p += be32(UInt32(4 + cpLen))
            p += le32(0x0000_0017)
            p += utf8[i ..< i + cpLen]
            send(p, channel: 0x02, label: "unicode len=\(cpLen)")
            i += cpLen
        }
    }

    // MARK: - Keyboard

    func handleKeyDown(_ event: NSEvent) {
        sendKey(event, down: true)
    }

    func handleKeyUp(_ event: NSEvent) {
        sendKey(event, down: false)
    }

    // flagsChanged fires when a modifier key (shift, ctrl, option, cmd) is pressed/released.
    // Synthesise key-down or key-up based on whether the flag is now set.
    func handleFlagsChanged(_ event: NSEvent) {
        guard let vk = macToWin32[Int(event.keyCode)] else { return }
        let flag = modifierFlag(for: event.keyCode)
        let down = event.modifierFlags.contains(flag)
        sendRawKey(vk: vk, modifiers: 0, down: down)
    }

    private func sendKey(_ event: NSEvent, down: Bool) {
        guard let vk = macToWin32[Int(event.keyCode)] else { return }
        let modifiers = appleToApolloModifiers(event.modifierFlags)
        sendRawKey(vk: vk, modifiers: modifiers, down: down)
    }

    // NV_KEYBOARD_PACKET:
    //   size = BE32(10)   — sizeof(magic) + sizeof(payload) = 4 + 6
    //   magic = LE32(0x03 keyDown | 0x04 keyUp)
    //   flags(1) + keyCode LE16(2) + modifiers(1) + zero(2)
    private func sendRawKey(vk: Int, modifiers: UInt8, down: Bool) {
        if down { heldKeys.insert(vk) } else { heldKeys.remove(vk) }
        let magic: UInt32 = down ? 0x0000_0003 : 0x0000_0004
        var p = [UInt8]()
        p += be32(10)
        p += le32(magic)
        p.append(0x01)                      // flags: key code is not normalized
        p += le16(UInt16(clamping: vk))     // VK code LE16
        p.append(modifiers)
        p += [0x00, 0x00]                   // padding
        send(p, channel: 0x02, label: "\(down ? "keyDown" : "keyUp") vk=0x\(String(format: "%02x", vk))")
    }

    // MARK: - Mouse movement

    func handleMouseMoved(_ event: NSEvent) {
        let (dx, dy) = rawDelta(from: event)
        pendingDX += dx
        pendingDY += dy
        // Send right away. AppKit has already coalesced rapid moves into this event, so there
        // is no flood, and crucially no fixed timer delay is added before the packet leaves
        // (matches moonlight-qt, which sends each motion event immediately). The accumulator
        // only carries a sub-pixel remainder to the next event.
        flushMouseMove()
    }

    // Truncates the integer portion, keeps the fractional remainder for the next event,
    // and splits deltas larger than Int16 into multiple packets to avoid clamping.
    private func flushMouseMove() {
        let ix = Int(pendingDX)   // truncate toward zero; fraction stays in accumulator
        let iy = Int(pendingDY)
        guard ix != 0 || iy != 0 else { return }
        pendingDX -= CGFloat(ix)
        pendingDY -= CGFloat(iy)

        // NV_MOUSE_MOVE_REL_PACKET: BE32(8) | LE32(0x07) | deltaX BE16 | deltaY BE16
        var remX = ix, remY = iy
        while remX != 0 || remY != 0 {
            let chunkX = Int16(clamping: remX)
            let chunkY = Int16(clamping: remY)
            guard chunkX != 0 || chunkY != 0 else { break }
            var p = [UInt8]()
            p += be32(8)
            p += le32(0x0000_0007)
            p += be16(UInt16(bitPattern: chunkX))
            p += be16(UInt16(bitPattern: chunkY))
            send(p, channel: 0x03, label: "mouseMove dx=\(chunkX) dy=\(chunkY)")
            remX -= Int(chunkX)
            remY -= Int(chunkY)
        }
    }

    // Use the pre-acceleration HID counts from the underlying CGEvent when available.
    // Falling back to event.deltaX/Y (which carry macOS pointer acceleration) is safe —
    // raw fields are absent on some VM environments and synthesised events.
    private func rawDelta(from event: NSEvent) -> (CGFloat, CGFloat) {
        if let cg = event.cgEvent {
            // kCGMouseEventRawMouseDeltaX/Y: CGEventField 119/120 — pre-acceleration HID counts
            let dx = cg.getDoubleValueField(CGEventField(rawValue: 119)!)
            let dy = cg.getDoubleValueField(CGEventField(rawValue: 120)!)
            if dx != 0 || dy != 0 { return (CGFloat(dx), CGFloat(dy)) }
        }
        return (event.deltaX, event.deltaY)
    }

    // MARK: - Mouse buttons

    func handleMouseDown(_ event: NSEvent) {
        sendMouseButton(event, down: true)
    }

    func handleMouseUp(_ event: NSEvent) {
        sendMouseButton(event, down: false)
    }

    // NV_MOUSE_BUTTON_PACKET:
    //   size = BE32(5)   — sizeof(magic) + sizeof(payload) = 4 + 1
    //   magic = LE32(0x08 down | 0x09 up)
    //   button(1): left=1, right=3, middle=2, x1=4, x2=5
    private func sendMouseButton(_ event: NSEvent, down: Bool) {
        guard let btn = apolloButton(event.buttonNumber) else { return }
        if down { heldButtons.insert(btn) } else { heldButtons.remove(btn) }
        let magic: UInt32 = down ? 0x0000_0008 : 0x0000_0009
        var p = [UInt8]()
        p += be32(5)
        p += le32(magic)
        p.append(btn)
        send(p, channel: 0x03, label: "\(down ? "mouseDown" : "mouseUp") btn=\(btn)")
    }

    // MARK: - Scroll wheel

    func handleScrollWheel(_ event: NSEvent) {
        // Scale: one standard detent = 120 for Win32 WHEEL_DELTA.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 3 : 120
        // Direction: Y un-negated (macOS scrollingDeltaY already encodes the Mac's scroll
        // setting and maps straight onto WHEEL_DELTA; matches moonlight, the old negation
        // flipped it); X negated. Clamp each event to ±one detent so a fast flick or macOS
        // scroll acceleration can't fire a wild burst the host scrolls through late (which
        // read as too-fast-and-laggy). This bounds the speed while preserving inertial/momentum
        // scrolling (the flick-to-coast); moonlight-qt clamps macOS deltas the same way.
        let amountY = Int16(clamping: Int(min(120, max(-120, event.scrollingDeltaY * scale))))
        let amountX = Int16(clamping: Int(min(120, max(-120, -event.scrollingDeltaX * scale))))

        // NV_SCROLL_PACKET    (0x0A)       — vertical:   BE32(10) | LE32(0x0A) | scrollAmt BE16 ×2 | zero(2)
        // SS_HSCROLL_PACKET   (0x55000001) — horizontal: BE32(6)  | LE32(0x55000001) | scrollAmount BE16 (one field)
        if amountY != 0 {
            var p = [UInt8]()
            p += be32(10)
            p += le32(0x0000_000A)
            p += be16(UInt16(bitPattern: amountY))
            p += be16(UInt16(bitPattern: amountY))
            p += [0x00, 0x00]
            send(p, channel: 0x03, label: "vscroll \(amountY)")
        }
        if amountX != 0 {
            // SS_HSCROLL_PACKET: BE32(6) | LE32(SS_HSCROLL_MAGIC=0x55000001) | scrollAmount BE16
            // Only one amount field (unlike NV_SCROLL_PACKET which has two).
            var p = [UInt8]()
            p += be32(6)
            p += le32(0x5500_0001)
            p += be16(UInt16(bitPattern: amountX))
            send(p, channel: 0x03, label: "hscroll \(amountX)")
        }
    }

    // MARK: - Send

    // Packets go PLAINTEXT to the transport. The ENet layer wraps them in
    // NVCTL_ENCRYPTED_PACKET_HEADER when encryptedControlStream (useReliableUdp=13) is active.
    // label is @autoclosure so the interpolated description is never built on the
    // hot path (mouse moves arrive at HID rate) — only for the first 8 logged
    // packets, and only when verbose logging is enabled.
    private func send(_ plaintext: [UInt8], channel: UInt8, label: @autoclosure () -> String) {
        packetsSent += 1
        if StreamLog.verbose && packetsSent <= 8 {
            StreamLog.log("[ChloroFrame][input] #\(packetsSent) \(label()) ch=0x\(String(format: "%02x", channel)) len=\(plaintext.count)B")
        }
        transport?.sendInput(packet: plaintext, channel: channel)
    }

    // MARK: - Helpers

    private func apolloButton(_ n: Int) -> UInt8? {
        switch n {
        case 0: return 1   // left
        case 1: return 3   // right
        case 2: return 2   // middle
        case 3: return 4   // x1
        case 4: return 5   // x2
        default: return nil
        }
    }

    private func appleToApolloModifiers(_ f: NSEvent.ModifierFlags) -> UInt8 {
        var m: UInt8 = 0
        if f.contains(.shift)   { m |= 0x01 }
        if f.contains(.control) { m |= 0x02 }
        if f.contains(.option)  { m |= 0x04 }
        if f.contains(.command) { m |= 0x08 }
        return m
    }

    private func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags {
        switch Int(keyCode) {
        case 0x38, 0x3C: return .shift
        case 0x3B, 0x3E: return .control
        case 0x3A, 0x3D: return .option
        case 0x37, 0x36: return .command
        case 0x39:       return .capsLock
        default:         return []
        }
    }

    // MARK: - Byte-order helpers

    private func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
         UInt8((v >>  8) & 0xFF), UInt8( v        & 0xFF)]
    }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8( v        & 0xFF), UInt8((v >>  8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func be16(_ v: UInt16) -> [UInt8] {
        [UInt8(v >> 8), UInt8(v & 0xFF)]
    }
    private func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }
}

// MARK: - macOS keyCode → Win32 Virtual Key mapping

// macOS key codes are from Carbon.h (kVK_*). Win32 VK codes match MSDN VK_* constants.
// Keys with no Win32 equivalent are omitted; Apollo drops unknown codes gracefully.
private let macToWin32: [Int: Int] = [
    // Letters (ANSI layout)
    0x00: 0x41, // A
    0x01: 0x53, // S
    0x02: 0x44, // D
    0x03: 0x46, // F
    0x04: 0x48, // H
    0x05: 0x47, // G
    0x06: 0x5A, // Z
    0x07: 0x58, // X
    0x08: 0x43, // C
    0x09: 0x56, // V
    0x0B: 0x42, // B
    0x0C: 0x51, // Q
    0x0D: 0x57, // W
    0x0E: 0x45, // E
    0x0F: 0x52, // R
    0x10: 0x59, // Y
    0x11: 0x54, // T
    0x1F: 0x4F, // O
    0x20: 0x55, // U
    0x22: 0x49, // I
    0x23: 0x50, // P
    0x25: 0x4C, // L
    0x26: 0x4A, // J
    0x28: 0x4B, // K
    0x2D: 0x4E, // N
    0x2E: 0x4D, // M

    // Digits
    0x12: 0x31, // 1
    0x13: 0x32, // 2
    0x14: 0x33, // 3
    0x15: 0x34, // 4
    0x16: 0x36, // 6
    0x17: 0x35, // 5
    0x19: 0x39, // 9
    0x1A: 0x37, // 7
    0x1C: 0x38, // 8
    0x1D: 0x30, // 0

    // Punctuation (OEM codes for US layout)
    0x18: 0xBB, // = / +       VK_OEM_PLUS
    0x1B: 0xBD, // - / _       VK_OEM_MINUS
    0x1E: 0xDD, // ] / }       VK_OEM_6
    0x21: 0xDB, // [ / {       VK_OEM_4
    0x27: 0xDE, // ' / "       VK_OEM_7
    0x29: 0xBA, // ; / :       VK_OEM_1
    0x2A: 0xDC, // \ / |       VK_OEM_5
    0x2B: 0xBC, // , / <       VK_OEM_COMMA
    0x2C: 0xBF, // / / ?       VK_OEM_2
    0x2F: 0xBE, // . / >       VK_OEM_PERIOD
    0x32: 0xC0, // ` / ~       VK_OEM_3

    // Control keys
    0x24: 0x0D, // Return      VK_RETURN
    0x30: 0x09, // Tab         VK_TAB
    0x31: 0x20, // Space       VK_SPACE
    0x33: 0x08, // Delete      VK_BACK (Backspace on Windows)
    0x35: 0x1B, // Escape      VK_ESCAPE
    0x75: 0x2E, // Fwd Delete  VK_DELETE

    // Modifier keys
    0x37: 0x5B, // Command L   VK_LWIN
    0x36: 0x5C, // Command R   VK_RWIN
    0x38: 0xA0, // Shift L     VK_LSHIFT
    0x3C: 0xA1, // Shift R     VK_RSHIFT
    0x3B: 0xA2, // Control L   VK_LCONTROL
    0x3E: 0xA3, // Control R   VK_RCONTROL
    0x3A: 0xA4, // Option L    VK_LMENU
    0x3D: 0xA5, // Option R    VK_RMENU
    0x39: 0x14, // Caps Lock   VK_CAPITAL

    // Navigation
    0x7B: 0x25, // Left        VK_LEFT
    0x7C: 0x27, // Right       VK_RIGHT
    0x7D: 0x28, // Down        VK_DOWN
    0x7E: 0x26, // Up          VK_UP
    0x73: 0x24, // Home        VK_HOME
    0x77: 0x23, // End         VK_END
    0x74: 0x21, // Page Up     VK_PRIOR
    0x79: 0x22, // Page Down   VK_NEXT

    // Function keys
    0x7A: 0x70, // F1
    0x78: 0x71, // F2
    0x63: 0x72, // F3
    0x76: 0x73, // F4
    0x60: 0x74, // F5
    0x61: 0x75, // F6
    0x62: 0x76, // F7
    0x64: 0x77, // F8
    0x65: 0x78, // F9
    0x6D: 0x79, // F10
    0x67: 0x7A, // F11
    0x6F: 0x7B, // F12

    // Numpad
    0x52: 0x60, // Numpad 0    VK_NUMPAD0
    0x53: 0x61, // Numpad 1
    0x54: 0x62, // Numpad 2
    0x55: 0x63, // Numpad 3
    0x56: 0x64, // Numpad 4
    0x57: 0x65, // Numpad 5
    0x58: 0x66, // Numpad 6
    0x59: 0x67, // Numpad 7
    0x5B: 0x68, // Numpad 8
    0x5C: 0x69, // Numpad 9
    0x41: 0x6E, // Numpad .    VK_DECIMAL
    0x43: 0x6A, // Numpad *    VK_MULTIPLY
    0x45: 0x6B, // Numpad +    VK_ADD
    0x4E: 0x6D, // Numpad -    VK_SUBTRACT
    0x4B: 0x6F, // Numpad /    VK_DIVIDE
    0x4C: 0x0D, // Numpad Enter → VK_RETURN
]
