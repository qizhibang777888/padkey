import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// 全局状态与业务逻辑:HID 事件 → 键盘合成;配置持久化;组合键录制
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var config = AppConfig.defaultConfig()
    @Published var connected = false
    @Published var deviceName = "未连接 — 请按任意键唤醒手柄"
    @Published var trusted = true
    @Published var activeInputs: Set<String> = []   // 实时高亮:按住亮、松开灭
    @Published var lastEvent: String?      // 最近事件(识别未命名按钮用)
    @Published var recordingId: String?    // 正在录制的行

    private var repeatTimers: [String: Timer] = [:]
    private var safetyTimers: [String: DispatchWorkItem] = [:]
    private var trustTimer: Timer?
    private var keyMonitor: Any?
    let configURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PadKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let c = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = c
        }
    }

    func start() {
        HIDMonitor.shared.onInput = { [weak self] id, down in self?.handleInput(id, down: down) }
        HIDMonitor.shared.onRawEvent = { [weak self] s in self?.lastEvent = s }
        HIDMonitor.shared.onConnect = { [weak self] ok, name in
            self?.connected = ok
            self?.deviceName = ok ? name : "未连接 — 请按任意键唤醒手柄"
        }
        HIDMonitor.shared.start()

        trusted = AXIsProcessTrusted()
        padLog("辅助功能授权:\(trusted ? "已授权" : "未授权")")
        if !trusted { startTrustPolling() }
    }

    func refreshTrust() {
        trusted = AXIsProcessTrusted()
        padLog("辅助功能授权:\(trusted ? "已授权" : "未授权")")
        if trusted {
            trustTimer?.invalidate()
        } else {
            startTrustPolling()
        }
    }

    // 「重新检测」按钮:权限 + 手柄连接一起查
    func recheckConnection() {
        refreshTrust()
        HIDMonitor.shared.recheckNow()
    }

    private func startTrustPolling() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self else { return }
            self.trusted = AXIsProcessTrusted()
            if self.trusted { t.invalidate() }
        }
    }

    // MARK: - 持久化(~/Library/Application Support/PadKey/config.json)

    func save() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configURL, options: .atomic)
        }
    }

    func setBinding(_ id: String, _ combo: KeyCombo?) {
        config.bindings[id] = combo
        save()
    }

    func resetBindings() {
        config = AppConfig.defaultConfig()
        save()
    }

    // MARK: - 录制组合键(可多个键 = 同时按下;⌘⇧⌥⌃ 修饰键自动附带)

    @Published var recordingKeys: [CGKeyCode] = []
    @Published var recordingModifiers: UInt32 = 0

    func startRecording(_ id: String) {
        cancelRecording()
        recordingId = id
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            // 只取设备无关的 ⌘⇧⌥⌃ 位(Carbon 设备相关位 0x1B00 是物理键状态,与 CGEventFlags 不同命名空间)
            self.recordingModifiers |= UInt32(ev.modifierFlags.rawValue) & KeyPoster.recordableModifierMask
            switch ev.keyCode {
            case 53:   // esc = 取消(Esc 本身不可绑定)
                self.cancelRecording()
            case 36 where self.recordingKeys.isEmpty:   // 空列表时 ↩ = 绑定回车本身
                self.recordingKeys.append(ev.keyCode)
                self.finishRecording()
            case 36:   // ↩ = 完成
                self.finishRecording()
            default:
                if !self.recordingKeys.contains(ev.keyCode) {
                    self.recordingKeys.append(ev.keyCode)
                }
            }
            return nil   // 吞掉按键,避免触发菜单快捷键(含 ⌘Q)
        }
    }

    func finishRecording() {
        if let id = recordingId, !recordingKeys.isEmpty {
            setBinding(id, KeyCombo(keyCodes: recordingKeys, modifiers: recordingModifiers))
        }
        cancelRecording()
    }

    func cancelRecording() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        recordingId = nil
        recordingKeys = []
        recordingModifiers = 0
    }

    // MARK: - 绑定测试(注入一次组合键,用本地事件回声验证是否真的进入系统事件流)

    struct TestOutcome: Equatable {
        let ok: Bool
        let text: String
    }

    @Published var testOutcomes: [String: TestOutcome] = [:]

    func runTest(_ id: String) {
        guard let combo = config.bindings[id], combo.isBound else {
            recordTest(id, TestOutcome(ok: false, text: "未绑定,先「录入」按键"))
            return
        }
        guard AXIsProcessTrusted() else {
            trusted = false
            startTrustPolling()
            recordTest(id, TestOutcome(ok: false, text: "无辅助功能权限 —— 重新编译 App 会使旧授权失效,请重新授权"))
            return
        }
        var sawEcho = false
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            if combo.keyCodes.contains(ev.keyCode) { sawEcho = true }
            return ev
        }
        KeyPoster.postDown(combo)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            KeyPoster.postUp(combo)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if let m = monitor { NSEvent.removeMonitor(m) }
            if sawEcho {
                AppModel.shared.recordTest(id, TestOutcome(ok: true, text: "注入成功,绑定有效"))
            } else {
                AppModel.shared.recordTest(id, TestOutcome(ok: false, text: "未捕获到注入(可能被系统拦截或前台已切换)"))
            }
        }
    }

    private func recordTest(_ id: String, _ outcome: TestOutcome) {
        testOutcomes[id] = outcome
        lastEvent = "测试:\(outcome.text)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.testOutcomes[id] == outcome { self?.testOutcomes.removeValue(forKey: id) }
        }
    }

    // MARK: - 输入 → 键盘合成

    private func handleInput(_ id: String, down: Bool) {
        // 实时高亮:按住亮、松开灭(与映射开关无关,便于验证按钮识别);15s 兜底防长亮
        if down {
            activeInputs.insert(id)
            safetyTimers[id]?.cancel()
            let w = DispatchWorkItem { [weak self] in
                self?.activeInputs.remove(id)
                self?.safetyTimers[id] = nil
            }
            safetyTimers[id] = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: w)
        } else {
            safetyTimers[id]?.cancel()
            safetyTimers[id] = nil
            activeInputs.remove(id)
        }

        guard let combo = config.bindings[id], combo.isBound else {
            if !down, let t = repeatTimers[id] { t.invalidate(); repeatTimers[id] = nil }
            return
        }
        if down {
            guard config.enabled else { return }
            KeyPoster.postDown(combo)
            startRepeat(id: id, combo: combo)
        } else {
            // 松开始终发 keyUp(即使映射已关),防止"粘键"
            stopRepeat(id: id)
            KeyPoster.postUp(combo)
        }
    }

    private func startRepeat(id: String, combo: KeyCombo) {
        stopRepeat(id: id)
        guard config.holdRepeat.enabled else { return }
        let delay = max(config.holdRepeat.delay, 0.05)
        let interval = max(config.holdRepeat.interval, 0.03)
        let first = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            KeyPoster.postRepeat(combo)
            let rep = Timer(timeInterval: interval, repeats: true) { _ in
                KeyPoster.postRepeat(combo)
            }
            RunLoop.main.add(rep, forMode: .common)
            self?.repeatTimers[id] = rep
        }
        RunLoop.main.add(first, forMode: .common)
        repeatTimers[id] = first
    }

    private func stopRepeat(id: String) {
        if let t = repeatTimers[id] { t.invalidate(); repeatTimers[id] = nil }
    }
}
