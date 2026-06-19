//
//  ControllerWire.swift
//  ChloroFrame
//
//  Host (Windows / Apollo) controller wire format. Byte layouts are a direct transcription of
//  moonlight-common-c (Input.h + InputStream.c, ClassicOldSong fork @ c999436):
//
//    NV_MULTI_CONTROLLER_PACKET (GEN5, magic 0x0C) — gamepad state, level-based.
//    SS_CONTROLLER_ARRIVAL_PACKET (magic 0x55000004) — announce a controller (Sunshine ext).
//
//  All multi-byte fields are little-endian except header.size (big-endian), matching the LE16/
//  LE32/BE32 calls in sendControllerEventInternal. Packets go to ENet control channels:
//  gamepad = 0x10 + controllerNumber, keyboard = 0x02 (Limelight-internal.h CTRL_CHANNEL_*).
//
//  Pure encoders + mapping tables; no I/O. The translator builds state and hands these bytes to
//  StreamTransport.sendInput(packet:channel:).
//

import Foundation

enum ControllerWire {

    // MARK: - ENet control channels

    static let channelKeyboard: UInt8 = 0x02
    static func channelGamepad(_ controllerNumber: Int) -> UInt8 { 0x10 + UInt8(controllerNumber & 0x0F) }

    // MARK: - Host gamepad button flags (Apollo src/platform/common.h)

    static func hostFlag(_ b: GamepadButton) -> UInt32 {
        switch b {
        case .a:                return 0x0000_1000
        case .b:                return 0x0000_2000
        case .x:                return 0x0000_4000
        case .y:                return 0x0000_8000
        case .leftBumper:       return 0x0000_0100
        case .rightBumper:      return 0x0000_0200
        case .dpadUp:           return 0x0000_0001
        case .dpadDown:         return 0x0000_0002
        case .dpadLeft:         return 0x0000_0004
        case .dpadRight:        return 0x0000_0008
        case .start:            return 0x0000_0010
        case .back:             return 0x0000_0020
        case .guide:            return 0x0000_0400
        case .leftStickButton:  return 0x0000_0040
        case .rightStickButton: return 0x0000_0080
        case .leftTrigger, .rightTrigger:
            return 0   // analog: set the trigger byte instead, see HostGamepadState.apply
        }
    }

    // MARK: - Host keyboard virtual-keys (Win32 VK_*) for the virtual-keyboard tokens

    static func winVK(_ token: String) -> Int? {
        let t = token.lowercased()
        switch t {
        case "ctrl":        return 0xA2   // VK_LCONTROL
        case "alt":         return 0xA4   // VK_LMENU
        case "shift":       return 0xA0   // VK_LSHIFT
        case "win":         return 0x5B   // VK_LWIN
        case "esc":         return 0x1B
        case "tab":         return 0x09
        case "enter", "numenter": return 0x0D
        case "space":       return 0x20
        case "backspace":   return 0x08
        case "delete":      return 0x2E
        case "capslock":    return 0x14
        case "insert":      return 0x2D
        case "home":        return 0x24
        case "end":         return 0x23
        case "pageup":      return 0x21
        case "pagedown":    return 0x22
        case "left":        return 0x25
        case "up":          return 0x26
        case "right":       return 0x27
        case "down":        return 0x28
        case "printscreen": return 0x2C
        case "scrolllock":  return 0x91
        case "pause":       return 0x13
        case "numlock":     return 0x90
        case "apps":        return 0x5D
        case "grave":       return 0xC0
        case "minus":       return 0xBD
        case "equal":       return 0xBB
        case "lbracket":    return 0xDB
        case "rbracket":    return 0xDD
        case "backslash":   return 0xDC
        case "semicolon":   return 0xBA
        case "quote":       return 0xDE
        case "comma":       return 0xBC
        case "period":      return 0xBE
        case "slash":       return 0xBF
        case "mute":        return 0xAD
        case "volumeup":    return 0xAF
        case "volumedown":  return 0xAE
        case "playpause":   return 0xB3
        case "stop":        return 0xB2
        case "prevtrack":   return 0xB1
        case "nexttrack":   return 0xB0
        default:
            if t.count == 1, let u = t.unicodeScalars.first {
                if (97...122).contains(u.value) { return Int(u.value) - 32 }      // a-z -> 0x41..
                if (48...57).contains(u.value)  { return Int(u.value) }           // 0-9 -> 0x30..
            }
            if t.hasPrefix("f"), let n = Int(t.dropFirst()), (1...12).contains(n) { return 0x70 + n - 1 }
            if t.hasPrefix("num"), let d = Int(t.dropFirst(3)), (0...9).contains(d) { return 0x60 + d }
            switch t {
            case "numdivide":   return 0x6F
            case "nummultiply": return 0x6A
            case "numsubtract": return 0x6D
            case "numadd":      return 0x6B
            case "numdecimal":  return 0x6E
            default:            return nil
            }
        }
    }

    // MARK: - Packet encoders

    // Magic + constant fields (Input.h).
    private static let MULTI_CONTROLLER_MAGIC_GEN5: UInt32 = 0x0000_000C
    private static let SS_CONTROLLER_ARRIVAL_MAGIC: UInt32 = 0x5500_0004
    private static let MC_HEADER_B: UInt16 = 0x001A
    private static let MC_MID_B: UInt16   = 0x0014
    private static let MC_TAIL_A: UInt16  = 0x009C
    private static let MC_TAIL_B: UInt16  = 0x0055

    /// NV_MULTI_CONTROLLER_PACKET (GEN5). 34 bytes total; size field = 30.
    static func multiController(controllerNumber: Int, activeGamepadMask: UInt16,
                               state: HostGamepadState) -> [UInt8] {
        var p = [UInt8]()
        p += be32(30)
        p += le32(MULTI_CONTROLLER_MAGIC_GEN5)
        p += le16(MC_HEADER_B)
        p += le16(UInt16(controllerNumber & 0xFFFF))
        p += le16(activeGamepadMask)
        p += le16(MC_MID_B)
        p += le16(UInt16(truncatingIfNeeded: state.buttonFlags))          // low 16 bits
        p.append(state.leftTrigger)
        p.append(state.rightTrigger)
        p += le16(UInt16(bitPattern: state.leftStickX))
        p += le16(UInt16(bitPattern: state.leftStickY))
        p += le16(UInt16(bitPattern: state.rightStickX))
        p += le16(UInt16(bitPattern: state.rightStickY))
        p += le16(MC_TAIL_A)
        p += le16(UInt16(truncatingIfNeeded: state.buttonFlags >> 16))    // buttonFlags2 (Sunshine)
        p += le16(MC_TAIL_B)
        return p
    }

    /// SS_CONTROLLER_ARRIVAL_PACKET. 16 bytes total; size field = 12.
    static func arrival(controllerNumber: Int, type: UInt8,
                        capabilities: UInt16, supportedButtonFlags: UInt32) -> [UInt8] {
        var p = [UInt8]()
        p += be32(12)
        p += le32(SS_CONTROLLER_ARRIVAL_MAGIC)
        p.append(UInt8(controllerNumber & 0xFF))
        p.append(type)
        p += le16(capabilities)
        p += le32(supportedButtonFlags)
        return p
    }

    /// NV_KEYBOARD_PACKET (magic 0x03 down / 0x04 up), matching InputHandler.sendRawKey.
    static func keyboard(vk: Int, modifiers: UInt8, down: Bool) -> [UInt8] {
        var p = [UInt8]()
        p += be32(10)
        p += le32(down ? 0x0000_0003 : 0x0000_0004)
        p.append(0x01)                                  // flags: key code not normalized
        p += le16(UInt16(clamping: vk))
        p.append(modifiers)
        p += [0x00, 0x00]
        return p
    }

    // MARK: - Byte-order helpers

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private static func le16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8(v >> 8)]
    }
}

// The host gamepad state for one controller (the level-based MULTI_CONTROLLER payload).
struct HostGamepadState: Equatable {
    var buttonFlags: UInt32 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var leftStickX: Int16 = 0
    var leftStickY: Int16 = 0
    var rightStickX: Int16 = 0
    var rightStickY: Int16 = 0

    /// Apply a target gamepad button: a flag bit, or full-press of an analog trigger.
    mutating func press(_ b: GamepadButton) {
        switch b {
        case .leftTrigger:  leftTrigger = 0xFF
        case .rightTrigger: rightTrigger = 0xFF
        default:            buttonFlags |= ControllerWire.hostFlag(b)
        }
    }
}
