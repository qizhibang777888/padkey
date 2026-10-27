import Foundation
import CoreGraphics

// MARK: - 键组合(多键同按 + 修饰键)

struct KeyCombo: Codable, Equatable {
    var keyCodes: [CGKeyCode]   // 空数组 = 未绑定;多个键 = 同时按下(如 A+B)
    var modifiers: UInt32       // CGEventFlags 设备无关位(⌘⇧⌥⌃,见 KeyPoster.modifiers)
    var isBound: Bool { !keyCodes.isEmpty }

    init(keyCodes: [CGKeyCode] = [], modifiers: UInt32 = 0) {
        self.keyCodes = keyCodes
        self.modifiers = modifiers
    }

    enum CodingKeys: String, CodingKey { case keyCodes, keyCode, modifiers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // v1.0 曾误存 NSEvent 的 Carbon 设备相关位,这里翻译成正确的 CGEventFlags 位
        let legacy = try c.decodeIfPresent(UInt32.self, forKey: .modifiers) ?? 0
        modifiers = KeyCombo.migrateModifiers(legacy)
        if let arr = try c.decodeIfPresent([CGKeyCode].self, forKey: .keyCodes) {
            keyCodes = arr
        } else if let single = try c.decodeIfPresent(CGKeyCode.self, forKey: .keyCode) {
            keyCodes = [single]   // v1.0 单键格式
        } else {
            keyCodes = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(keyCodes, forKey: .keyCodes)
        try c.encode(modifiers, forKey: .modifiers)
    }

    // Carbon 设备相关修饰位(⌘0x100 ⇧0x200 ⌥0x800 ⌃0x1000)→ CGEventFlags 设备无关位
    static func migrateModifiers(_ v: UInt32) -> UInt32 {
        var r = v
        if r & 0x0100 != 0 { r = (r & ~0x0100) | UInt32(CGEventFlags.maskCommand.rawValue) }
        if r & 0x0200 != 0 { r = (r & ~0x0200) | UInt32(CGEventFlags.maskShift.rawValue) }
        if r & 0x0800 != 0 { r = (r & ~0x0800) | UInt32(CGEventFlags.maskAlternate.rawValue) }
        if r & 0x1000 != 0 { r = (r & ~0x1000) | UInt32(CGEventFlags.maskControl.rawValue) }
        return r
    }
}

// MARK: - 手柄输入定义与检测规则

enum DetectRule {
    case button(usage: UInt32)                     // page 9 按钮
    case hat(value: Int)                           // page1 usage57 十字键档位
    case trigger(usage: UInt32)                    // page2 模拟扳机
    case stickAxis(usage: UInt32, negative: Bool)  // page1 摇杆轴半区
}

struct PadInputDef: Identifiable {
    let id: String
    let label: String
    let group: String
    let rule: DetectRule
}

// 2026-10-27 pad-diag 实测(GameSir G40 Pro,Xbox 模式 BLE):
//   page9 usage:1=A 2=B 4=X 5=Y 7=LB 8=RB 11=View 12=Menu 15=R3(按下时右摇杆受力佐证)
//   十字键 hat:↑=1 →=3 ↓=5 ←=7(标准 HID hat 布局;2026-10-27 v1.3 用户实测修正,pad-diag 首录方向有误);斜向(2/4/6/8)不映射
//   usage 10=L3 为推测;3/6/9/13/14 未识别(G/Home、M1/M2 之类),做成"未识别按钮"行
let padGroups = ["扳机", "肩键", "主要按钮", "十字键", "摇杆点击", "摇杆方向", "系统键", "未识别按钮"]

let padInputCatalog: [PadInputDef] = [
    .init(id: "lt", label: "LT 左扳机", group: "扳机", rule: .trigger(usage: 197)),
    .init(id: "rt", label: "RT 右扳机", group: "扳机", rule: .trigger(usage: 196)),
    .init(id: "lb", label: "LB 左肩键", group: "肩键", rule: .button(usage: 7)),
    .init(id: "rb", label: "RB 右肩键", group: "肩键", rule: .button(usage: 8)),
    .init(id: "a", label: "A", group: "主要按钮", rule: .button(usage: 1)),
    .init(id: "b", label: "B", group: "主要按钮", rule: .button(usage: 2)),
    .init(id: "x", label: "X", group: "主要按钮", rule: .button(usage: 4)),
    .init(id: "y", label: "Y", group: "主要按钮", rule: .button(usage: 5)),
    .init(id: "dpadUp", label: "十字 ↑", group: "十字键", rule: .hat(value: 1)),
    .init(id: "dpadRight", label: "十字 →", group: "十字键", rule: .hat(value: 3)),
    .init(id: "dpadDown", label: "十字 ↓", group: "十字键", rule: .hat(value: 5)),
    .init(id: "dpadLeft", label: "十字 ←", group: "十字键", rule: .hat(value: 7)),
    .init(id: "l3", label: "L3 左摇杆按下(待验证)", group: "摇杆点击", rule: .button(usage: 10)),
    .init(id: "r3", label: "R3 右摇杆按下", group: "摇杆点击", rule: .button(usage: 15)),
    .init(id: "lsLeft", label: "左摇杆 ←", group: "摇杆方向", rule: .stickAxis(usage: 48, negative: true)),
    .init(id: "lsRight", label: "左摇杆 →", group: "摇杆方向", rule: .stickAxis(usage: 48, negative: false)),
    .init(id: "lsUp", label: "左摇杆 ↑", group: "摇杆方向", rule: .stickAxis(usage: 49, negative: true)),
    .init(id: "lsDown", label: "左摇杆 ↓", group: "摇杆方向", rule: .stickAxis(usage: 49, negative: false)),
    .init(id: "rsLeft", label: "右摇杆 ←", group: "摇杆方向", rule: .stickAxis(usage: 50, negative: true)),
    .init(id: "rsRight", label: "右摇杆 →", group: "摇杆方向", rule: .stickAxis(usage: 50, negative: false)),
    .init(id: "rsUp", label: "右摇杆 ↑", group: "摇杆方向", rule: .stickAxis(usage: 53, negative: true)),
    .init(id: "rsDown", label: "右摇杆 ↓", group: "摇杆方向", rule: .stickAxis(usage: 53, negative: false)),
    .init(id: "view", label: "View 视图键", group: "系统键", rule: .button(usage: 11)),
    .init(id: "menu", label: "Menu 菜单键", group: "系统键", rule: .button(usage: 12)),
    .init(id: "btn3", label: "按钮 3(未识别)", group: "未识别按钮", rule: .button(usage: 3)),
    .init(id: "btn6", label: "按钮 6(未识别)", group: "未识别按钮", rule: .button(usage: 6)),
    .init(id: "btn9", label: "按钮 9(未识别)", group: "未识别按钮", rule: .button(usage: 9)),
    .init(id: "btn13", label: "按钮 13(未识别)", group: "未识别按钮", rule: .button(usage: 13)),
    .init(id: "btn14", label: "按钮 14(未识别)", group: "未识别按钮", rule: .button(usage: 14)),
]

// MARK: - 配置(持久化到 ~/Library/Application Support/PadKey/config.json)

struct RepeatConfig: Codable, Equatable {
    var enabled = true
    var delay = 0.4      // 按住后首次重复延迟(秒)
    var interval = 0.12  // 重复间隔(秒)
}

struct AppConfig: Codable, Equatable {
    var version = 1
    var enabled = true
    var holdRepeat = RepeatConfig()
    var bindings: [String: KeyCombo] = [:]

    static func defaultConfig() -> AppConfig {
        var c = AppConfig()
        c.bindings["lt"] = KeyCombo(keyCodes: [123], modifiers: 0)   // ←
        c.bindings["rt"] = KeyCombo(keyCodes: [124], modifiers: 0)   // →
        return c
    }
}
