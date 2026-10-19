# 验证说明

## 2026-10-19 发布整理结果

- 纯逻辑测试通过：35 个按键状态场景与 21 个解码 / 筛选断言。
- macOS 12 目标的 arm64、x86_64 编译通过，通用二进制架构检查通过。
- Info.plist 格式与 ad-hoc 签名校验通过；没有 Apple 公证。
- 本次没有启动应用、申请权限、接管实机线控、录音或向 UU 发送文字。物理耳机与远端链路仍需手工验收。

## 测试边界

`test.sh` 只编译 `MappingCore.swift` 与 `Tests/main.swift`。它使用合成数据检查 HID 解码、精确设备筛选、按下与释放配对、重复报告去重、180 毫秒去抖、资格切换、修饰键抑制与状态重置，不会抓取真实 HID、录音或注入按键。

`build.sh` 编译 macOS 12 目标的 arm64 与 x86_64 二进制、合并为通用可执行文件、校验 Info.plist 并验证 ad-hoc 签名。它不会启动应用或请求权限。编译 Intel 架构并不等于已经在 Intel Mac 上运行验证。

发布整理只运行上述构建与纯逻辑测试。此前本机设备接管观察与个人验证记录不作为本仓库的通用兼容性保证，也不随源码发布。

## 用户手工验收

1. 只运行一个耳机桥接实例，确认辅助功能授权生效、匹配耳机接管成功。
2. 先在普通本地输入框确认豆包 Fn 基线正常，再按耳机中间键，确认豆包接受合成 Fn，能够开始并结束语音。
3. 确认中间键不会播放 / 暂停音乐，音量加减与长按重复正常。
4. 按住修饰键再按中间键，确认不会额外启动听写；暂停与退出后应恢复系统线控行为。
5. 与 UU 桥接联用时，先确认两台 Mac 的文字剪贴板同步，再确认 Fn 开框、框内豆包录音 / 转写和远端发送各步骤。

出现接管冲突时退出其他映射工具。若目标输入法不接受合成 Fn，应如实报告对应系统与输入法版本；不要把图标、录音浮条或 Fn 逻辑测试通过视为转写成功。

## 实现线索

- `Sources/HeadsetCapture.swift`：精确设备匹配、独占打开与释放。
- `Sources/MappingCore.swift`：消费者用法解码、去重、抑制与配对逻辑。
- `Sources/AudioRoute.swift`：CoreAudio 连接条件；它不读取音频流。
- `Sources/main.swift`：菜单、偏好、Fn 和音量事件合成。

Fn 使用虚拟键码 `63`、`flagsChanged`、`maskSecondaryFn`，按下后约 60 毫秒释放。Fn 与音量事件携带 `eventSourceUserData = 0x444f5542414f`（ASCII `DOUBAO`）。UU 桥接器可借此识别受支持的耳机入口。它只标记软件来源，不保证后续消费者接受这些事件。

独占接口使用 Apple 的 [IOHIDDeviceOpen](https://developer.apple.com/documentation/iokit/1588670-iohiddeviceopen) 与 `kIOHIDOptionsTypeSeizeDevice`。具体运行行为应以目标系统的返回结果和手工验收为准。
