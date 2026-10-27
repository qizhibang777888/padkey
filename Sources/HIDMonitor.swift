import IOKit
import IOKit.hid
import Foundation
import os

// NSLog 的动态内容会被统一日志脱敏成 <private>,排查时全靠猜;
// os_log 的 %{public} 显式公开,`log show --predicate 'subsystem == "local.qzbworks.padkey"'` 可直接看到
private let padLogOSLog = OSLog(subsystem: "local.qzbworks.padkey", category: "hid")

func padLog(_ message: String) {
    os_log("%{public}@", log: padLogOSLog, type: .default, message)
}

// IOHIDManager 后台监听 —— manager 级 value 回调
// (2026-10-27 pad-diag 实测:按钮/十字键/摇杆/扳机全部事件都能收到)
final class HIDMonitor {
    static let shared = HIDMonitor()

    var onInput: ((String, Bool) -> Void)?    // (输入 id, 是否按下)
    var onRawEvent: ((String) -> Void)?       // 最近事件描述(调试/识别未命名按钮)
    var onConnect: ((Bool, String) -> Void)?  // (已连接, 设备名)

    private var mgr: IOHIDManager?
    private var inputStates: [String: Bool] = [:]
    private let triggerOn = 0.60, triggerOff = 0.35   // 扳机滞回阈值(占量程比例)
    private let stickOn = 0.60, stickOff = 0.35       // 摇杆半区滞回阈值

    private var buttonsByUsage: [UInt32: [PadInputDef]] = [:]
    private var hats: [PadInputDef] = []
    private var triggersByUsage: [UInt32: [PadInputDef]] = [:]
    private var sticksByUsage: [UInt32: [PadInputDef]] = [:]

    private var pollTimer: Timer?
    private var rebuilding = false

    private init() {
        for def in padInputCatalog {
            switch def.rule {
            case .button(let u): buttonsByUsage[u, default: []].append(def)
            case .hat: hats.append(def)
            case .trigger(let u): triggersByUsage[u, default: []].append(def)
            case .stickAxis(let u, _): sticksByUsage[u, default: []].append(def)
            }
        }
    }

    func start() {
        guard mgr == nil else { return }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let match: [String: Any] = [kIOHIDVendorIDKey: 0x045E, kIOHIDProductIDKey: 0x0B13]
        IOHIDManagerSetDeviceMatching(m, match as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(m, HIDMonitor.deviceCallback, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(m, HIDMonitor.removalCallback, nil)
        IOHIDManagerRegisterInputValueCallback(m, HIDMonitor.valueCallback, nil)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, 0)
        padLog(r == kIOReturnSuccess
               ? "manager 已创建并打开,开始匹配设备"
               : "IOHIDManagerOpen 失败 0x" + String(format: "%08x", r))
        mgr = m
        startPolling()
    }

    // MARK: - 断连自愈与连接状态
    // BLE 手柄休眠重连后,IOHIDManager 的「设备接入」回调可能不触发,但其内部设备集合
    // 会照常更新并自动 open(2026-10-27 实测:回调丢了,设备集合却有两个)——所以只比
    // 数量的自愈是盲的,UI 会永远卡在「未连接」。对策:
    // ①连接状态每 2 秒直接以 IOKit 注册表为准纠偏,不依赖回调;
    // ②注册表与 manager 数量不一致时整体重建 manager(全新 manager 的匹配可靠);
    // ③检测到「回调丢失」时再重建一次,让 value 回调挂到干净的 manager 上。

    private var lastReportedConnected = false
    private var lastReportedName: String?

    // 统一出口:仅在状态变化时通知 UI,避免每 2 秒重复触发
    private func setConnected(_ ok: Bool, name: String) {
        if ok != lastReportedConnected || (ok && name != lastReportedName) {
            onConnect?(ok, ok ? name : "")
        }
        lastReportedConnected = ok
        if ok { lastReportedName = name }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            HIDMonitor.shared.reconcile()
        }
    }

    func recheckNow() {
        padLog("手动重新检测")
        reconcile()
    }

    private func managerDeviceCount() -> Int {
        guard let m = mgr, let devs = IOHIDManagerCopyDevices(m) else { return 0 }
        return CFSetGetCount(devs)
    }

    // 同步扫描 IOKit 注册表:目标手柄的 IOHIDUserDevice 服务数 + 设备名(绕过 manager 缓存)
    private func registryScan() -> (count: Int, name: String?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDUserDevice"), &iterator) == kIOReturnSuccess else {
            return (-1, nil)   // 扫描失败:count 为 -1 表示未知,不据此变更状态
        }
        defer { IOObjectRelease(iterator) }
        var count = 0
        var name: String?
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            let vid = (IORegistryEntryCreateCFProperty(entry, "VendorID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            let pid = (IORegistryEntryCreateCFProperty(entry, "ProductID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            if vid == 0x045E && pid == 0x0B13 {
                count += 1
                if name == nil {
                    name = (IORegistryEntryCreateCFProperty(entry, "Product" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String)
                }
            }
            IOObjectRelease(entry)
        }
        return (count, name)
    }

    private func reconcile() {
        guard !rebuilding, mgr != nil else { return }
        let (reg, regName) = registryScan()
        guard reg >= 0 else { return }   // 注册表扫描失败,本轮跳过
        let mgrCount = managerDeviceCount()

        if reg == 0 {
            if mgrCount > 0 {
                padLog("自愈重建:手柄已离开,manager 仍残留 \(mgrCount) 个设备")
                rebuild()
                return
            }
            if lastReportedConnected {
                padLog("注册表已无手柄服务,标记断开")
                setConnected(false, name: "")
                releaseAll()
            }
            return
        }

        // 手柄服务在注册表里:连接状态以注册表为准(「设备接入」回调可能丢失)
        let callbackLost = !lastReportedConnected
        if callbackLost {
            padLog("纠正连接状态:注册表有 \(reg) 个服务但未上报过连接(匹配回调丢失)")
        }
        setConnected(true, name: lastReportedName ?? regName ?? "GameSir 手柄")

        if mgrCount == 0 {
            padLog("自愈重建:注册表 \(reg) 个服务,manager 0 个")
            rebuild()
            return
        }
        if callbackLost {
            padLog("匹配回调丢失(注册表 \(reg)/manager \(mgrCount)),重建 manager 以恢复事件流")
            rebuild()
        }
    }

    private func rebuild() {
        rebuilding = true
        defer { rebuilding = false }
        if let m = mgr {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(m, 0)
            mgr = nil
        }
        releaseAll()   // 清掉可能粘住的按下状态(补发 keyUp)
        start()
    }

    // MARK: - C 回调(不能捕获上下文 → 静态闭包转发到单例)

    private static let deviceCallback: IOHIDDeviceCallback = { _, result, _, device in
        guard result == kIOReturnSuccess else {
            padLog("设备匹配回调异常:0x" + String(format: "%x", result))
            return
        }
        var name = "GameSir 手柄"
        if let v = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String { name = v }
        padLog("设备接入(\(name))")
        HIDMonitor.shared.setConnected(true, name: name)
    }

    private static let removalCallback: IOHIDDeviceCallback = { _, result, _, _ in
        guard result == kIOReturnSuccess else {
            padLog("设备移除回调异常:0x" + String(format: "%x", result))
            return
        }
        padLog("设备移除")
        HIDMonitor.shared.setConnected(false, name: "")
        HIDMonitor.shared.releaseAll()
    }

    private static let valueCallback: IOHIDValueCallback = { _, result, _, value in
        guard result == kIOReturnSuccess else { return }
        HIDMonitor.shared.handle(value)
    }

    // MARK: - 事件分类与状态机

    private func releaseAll() {
        for (id, pressed) in inputStates where pressed {
            inputStates[id] = false
            onInput?(id, false)
        }
    }

    private func setPressed(_ id: String, _ down: Bool) {
        if inputStates[id] != down {
            inputStates[id] = down
            onInput?(id, down)
        }
    }

    private func handle(_ value: IOHIDValue) {
        let elem = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let raw = IOHIDValueGetIntegerValue(value)
        let cookie = IOHIDElementGetCookie(elem)

        switch page {
        case 9:   // 按钮
            onRawEvent?("按钮 usage=\(usage) cookie=\(cookie) raw=\(raw)")
            for def in buttonsByUsage[usage] ?? [] {
                setPressed(def.id, raw != 0)
            }
        case 1 where usage == 57:   // 十字键(hat)
            onRawEvent?("十字键 raw=\(raw)")
            for def in hats {
                guard case .hat(let hv) = def.rule else { continue }
                setPressed(def.id, hv == raw)
            }
        case 2:   // 模拟扳机
            let lmax = Double(IOHIDElementGetLogicalMax(elem))
            guard lmax > 1 else { break }
            onRawEvent?("扳机 usage=\(usage) raw=\(raw)")
            for def in triggersByUsage[usage] ?? [] {
                let alreadyDown = inputStates[def.id] ?? false
                let t = alreadyDown ? triggerOff : triggerOn
                setPressed(def.id, Double(raw) >= lmax * t)
            }
        case 1:   // 摇杆轴 48/49/50/53
            guard let defs = sticksByUsage[usage], !defs.isEmpty else { break }
            onRawEvent?("摇杆 usage=\(usage) raw=\(raw)")
            let lmin = Double(IOHIDElementGetLogicalMin(elem))
            let lmax = Double(IOHIDElementGetLogicalMax(elem))
            guard lmax > lmin else { break }
            let center = (lmin + lmax) / 2
            let half = (lmax - lmin) / 2
            for def in defs {
                guard case .stickAxis(_, let negative) = def.rule else { continue }
                let ratio = (inputStates[def.id] ?? false) ? stickOff : stickOn
                let down = negative
                    ? Double(raw) < center - half * ratio
                    : Double(raw) > center + half * ratio
                setPressed(def.id, down)
            }
        default:
            break
        }
    }
}
