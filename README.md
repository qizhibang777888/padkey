# PadKey

macOS 手柄按键映射工具 —— 把蓝牙手柄按键映射为键盘组合键,让不认手柄的 Mac 应用也能用手柄操作。

针对 GameSir G40 Pro(Xbox 模式蓝牙)开发:IOKit HID 后台监听 + CGEvent 合成键盘事件,目标应用无需在前台、无需支持手柄。

## 功能

- **全按键绑定**:扳机 / 肩键 / ABXY / 十字键 / 摇杆方向半区 / L3·R3 / 系统键,未识别按键单独分组待认领
- **组合键**:单键或多键同按(如 `A+B`),⌘⇧⌥⌃ 修饰键自动附带
- **按住自动重复**:可开关,延迟与间隔可调
- **实时高亮**:按住亮灯、松开灭,直接确认按键识别
- **每行「测试」按钮**:注入一次组合键并自动验证事件是否进入系统
- **断连自愈**:手柄休眠唤醒后 2 秒内自动恢复连接与映射(连接状态直接以 IOKit 注册表为准,不依赖 HID 回调)
- **配置持久化**:`~/Library/Application Support/PadKey/config.json`
- 关闭窗口或 ⌘Q 即退出并停用映射

## 环境要求

- macOS 13+
- Xcode Command Line Tools(仅 `swiftc`,无需 Xcode 工程)
- 辅助功能权限(系统设置 → 隐私与安全性 → 辅助功能)

## 构建与运行

```bash
./build.sh
open PadKey.app
```

`build.sh` 用 `swiftc -O` 编译 `Sources/`,组装 `PadKey.app`,从 `Assets/icon.png` 生成全套图标,并优先用本地自签证书「PadKey Local Signer」签名 —— 签名身份跨编译稳定,重编译后辅助功能授权不会失效(无证书时回退 ad-hoc,每次重编译需重新授权)。

## 使用

1. 首次打开按提示授予辅助功能权限
2. 手柄以 Xbox 模式蓝牙连接 Mac(默认已绑定 LT=←、RT=→)
3. 点某行的绑定框或「录入」→ 逐个按键盘键(可多键)→ ↩ 完成、esc 取消
4. 点「测试」验证注入;按手柄按键看行高亮确认识别

## 适配其他手柄

默认匹配 VID `0x045E` / PID `0x0B13`(GameSir G40 Pro Xbox 模式)。换手柄时:

- `Sources/HIDMonitor.swift`:改 `IOHIDManagerSetDeviceMatching` 的 VID/PID 与注册表扫描判断
- `Sources/Models.swift`:按新设备的 HID usage 表调整 `padInputCatalog` 输入目录
