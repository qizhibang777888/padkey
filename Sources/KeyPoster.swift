import CoreGraphics
import Foundation

// CGEvent 合成键盘事件(需「辅助功能」权限)
enum KeyPoster {
    // 修饰键:CGEventFlags 设备无关位 → 虚拟键码 + 符号(显示/按下顺序固定 ⌃⌥⇧⌘)
    static let modifiers: [(flag: UInt32, code: CGKeyCode, symbol: String)] = [
        (UInt32(CGEventFlags.maskControl.rawValue), 59, "⌃"),
        (UInt32(CGEventFlags.maskAlternate.rawValue), 58, "⌥"),
        (UInt32(CGEventFlags.maskShift.rawValue), 56, "⇧"),
        (UInt32(CGEventFlags.maskCommand.rawValue), 55, "⌘"),
    ]

    static func modifierCodes(_ flags: UInt32) -> [CGKeyCode] {
        modifiers.filter { flags & $0.flag != 0 }.map(\.code)
    }

    // 录制时只保留这些修饰键位(NSEvent.modifierFlags 的设备无关部分;
    // 勿用 0x1B00 等 Carbon 设备相关位 —— 那是物理键状态,与 CGEventFlags 不同命名空间)
    static let recordableModifierMask: UInt32 = modifiers.reduce(0) { $0 | $1.flag }

    private static func flagsOf(_ combo: KeyCombo) -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(combo.modifiers))
    }

    // 完整按下:先 flagsChanged 按下修饰键 → 依次 keyDown 全部主键(多键 = 同按)
    static func postDown(_ combo: KeyCombo) {
        guard !combo.keyCodes.isEmpty else { return }
        let flags = flagsOf(combo)
        for m in modifierCodes(combo.modifiers) {
            post(key: m, down: true, flags: flags)
        }
        for k in combo.keyCodes {
            post(key: k, down: true, flags: flags)
        }
    }

    // 完整松开:逆序 keyUp 全部主键 → flagsChanged 释放修饰键
    static func postUp(_ combo: KeyCombo) {
        guard !combo.keyCodes.isEmpty else { return }
        let flags = flagsOf(combo)
        for k in combo.keyCodes.reversed() {
            post(key: k, down: false, flags: flags)
        }
        for m in modifierCodes(combo.modifiers).reversed() {
            post(key: m, down: false, flags: [])
        }
    }

    // 按住重复:修饰键已处于按下态,重发全部主键 keyDown
    static func postRepeat(_ combo: KeyCombo) {
        guard !combo.keyCodes.isEmpty else { return }
        let flags = flagsOf(combo)
        for k in combo.keyCodes {
            post(key: k, down: true, flags: flags)
        }
    }

    private static func post(key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { return }
        ev.flags = flags
        ev.post(tap: .cghidEventTap)
    }
}
