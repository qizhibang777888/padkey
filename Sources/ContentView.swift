import SwiftUI
import AppKit
import ApplicationServices

// 单行:指示灯 | 手柄按键名 | 组合键(展示/录制)| 录入/取消 | 清除
struct BindingRow: View {
    let def: PadInputDef
    @ObservedObject var model: AppModel

    private var isRecording: Bool { model.recordingId == def.id }
    private var isActive: Bool { model.activeInputs.contains(def.id) }
    private var combo: KeyCombo? { model.config.bindings[def.id] }

    private var recordingText: String {
        var s = ""
        for m in KeyPoster.modifiers where model.recordingModifiers & m.flag != 0 { s += m.symbol }
        let keys = model.recordingKeys.map(keyDisplayName).joined(separator: "+")
        return keys.isEmpty ? s : s + keys
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isActive ? Color.green : Color(nsColor: .quaternaryLabelColor))
                .frame(width: 8, height: 8)
            Text(def.label)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
            if isRecording {
                HStack(spacing: 8) {
                    Image(systemName: "keyboard")
                    Text(model.recordingKeys.isEmpty
                         ? "按键盘添加按键…(可多键;↩ 完成,esc 取消)"
                         : recordingText)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer()
                    Button("完成") { model.finishRecording() }
                        .disabled(model.recordingKeys.isEmpty)
                    Button("取消") { model.cancelRecording() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(comboDisplay(combo))
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { model.startRecording(def.id) }
            }
            Button("录入") { model.startRecording(def.id) }
                .buttonStyle(.link)
                .disabled(isRecording)
            Button("测试") { model.runTest(def.id) }
                .buttonStyle(.link)
                .disabled(!(combo?.isBound ?? false))
            if let outcome = model.testOutcomes[def.id] {
                Image(systemName: outcome.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(outcome.ok ? Color.green : Color.red)
                    .help(outcome.text)
            }
            Button {
                model.setBinding(def.id, nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("清除绑定")
            .disabled(combo?.isBound != true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? Color.green.opacity(0.15) : Color.clear)
        )
    }
}

struct ContentView: View {
    @ObservedObject var model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.trusted { permissionBanner }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(padGroups, id: \.self) { group in
                        let defs = padInputCatalog.filter { $0.group == group }
                        if !defs.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(group)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 12)
                                    .padding(.bottom, 4)
                                ForEach(defs) { def in
                                    BindingRow(def: def, model: model)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 680)
        .onChange(of: model.config) { _ in model.save() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(model.connected ? Color.green : Color.red).frame(width: 10, height: 10)
            Text(model.connected ? "已连接:\(model.deviceName)" : model.deviceName)
                .font(.callout)
                .lineLimit(1)
            if !model.connected {
                Button("重新检测") { model.recheckConnection() }
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Spacer()
            Toggle("启用映射", isOn: $model.config.enabled)
                .toggleStyle(.switch)
        }
        .padding(12)
    }

    private var permissionBanner: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("需要「辅助功能」权限才能注入键盘事件")
                    .font(.callout)
                Spacer()
                Button("去授权") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                Button("重新检测") { model.recheckConnection() }
            }
            Text("若设置里已勾选仍提示:重新编译过 App 会让旧授权失效 —— 请先在辅助功能列表中移除 PadKey,再重新添加并勾选")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Toggle("按住自动重复", isOn: $model.config.holdRepeat.enabled)
                Spacer()
                Button("恢复默认(LT=←,RT=→)") { model.resetBindings() }
            }
            HStack {
                Text(model.lastEvent.map { "最近事件:\($0)" } ?? "最近事件:—")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text("关闭窗口或 ⌘Q 退出后,映射即停用")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }
}
