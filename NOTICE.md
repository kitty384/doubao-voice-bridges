# 来源与许可声明

本仓库把两个独立 macOS 工具整理为一个源码仓库。各子项目保留其原有 MIT 许可证和版权声明；根目录新增文档、构建入口及仓库整理内容使用根目录的 [MIT 许可证](LICENSE)。分发子项目或其重要部分时，应一并保留对应的版权与许可声明。

## UU 远控听写 Fn

- 上游：[yupeng316888-create/DoubaoVoiceBridge](https://github.com/yupeng316888-create/DoubaoVoiceBridge)。
- 上游基线提交：[2429a8fefb84c94e7fd9e3bebd79500cf68784b0](https://github.com/yupeng316888-create/DoubaoVoiceBridge/commit/2429a8fefb84c94e7fd9e3bebd79500cf68784b0)。
- 原版权声明：`Copyright (c) 2026 yupeng316888-create`。
- 原许可证全文保留于 [apps/uu-voice-bridge/LICENSE](apps/uu-voice-bridge/LICENSE)。

本仓库的 2.5.1 / build 11 由此前的 2.5.0 Fn 派生版本继续修改，并非上游原样副本。派生改动包括实际 Fn / Globe 事件处理、本地发送框入口、剪贴板与原目标窗口核对、独立事件线程、手动启用和单实例保护。

2.5.1 增加与耳机工具的本机开框请求及确认、原窗口草稿恢复、监听状态诊断和进入 UU 时的一次有界刷新。默认首次 Fn 只开框；旧的长按听写路径改为菜单中的兼容选项。这仍是分步操作，不包含一次点击同时开框并切换录音的实验方案，也不代表上游作者已验证或支持这些修改。

## 豆包耳机语音桥接

- 当前应用版本：1.2 / build 3，由 1.1 继续修改。
- 原版权声明：`Copyright (c) 2026 Doubao Headset Bridge contributors`。
- 许可证全文保留于 [apps/headset-bridge/LICENSE](apps/headset-bridge/LICENSE)。

程序独占匹配的音频插孔消费者接口，在本地有效中间键按下时发送一次约 60 毫秒的 Fn 脉冲。1.2 在 UU 前台改为向远控桥接发送本机开框请求；在本地发送框中，后续点击仍交给豆包的 Fn 设置处理。接管范围、失败处理及验证边界见子项目文档。

## 第三方软件

豆包语音输入法、网易 UU 远程和 macOS 是独立的第三方软件，不随本仓库分发，也不适用本仓库的 MIT 许可证。名称用于说明兼容目标，不表示其厂商参与开发、提供担保或认可本项目。
