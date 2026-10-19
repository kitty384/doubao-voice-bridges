# 来源与许可声明

本仓库把两个独立 macOS 工具整理为一个源码仓库。各子项目保留其原有 MIT 许可证和版权声明；根目录新增文档、构建入口及仓库整理内容使用根目录的 [MIT 许可证](LICENSE)。分发子项目或其重要部分时，应一并保留对应的版权与许可声明。

## UU 远控听写 Fn

- 上游：[yupeng316888-create/DoubaoVoiceBridge](https://github.com/yupeng316888-create/DoubaoVoiceBridge)。
- 上游基线提交：[2429a8fefb84c94e7fd9e3bebd79500cf68784b0](https://github.com/yupeng316888-create/DoubaoVoiceBridge/commit/2429a8fefb84c94e7fd9e3bebd79500cf68784b0)。
- 原版权声明：`Copyright (c) 2026 yupeng316888-create`。
- 原许可证全文保留于 [apps/uu-voice-bridge/LICENSE](apps/uu-voice-bridge/LICENSE)。

本仓库发布的是由该基线继续修改的 2.5.0 Fn 版本，并非上游原样副本。派生改动包括实际 Fn / Globe 事件处理、本地发送框的轻按入口、保留长按听写路径、识别耳机程序的 Fn 来源标记、剪贴板与目标窗口核对，以及独立事件线程、手动启用和单实例保护。

本次公开整理保留 2.5.0 的功能代码，补充构建、测试入口和说明，并将构建产物收纳到子项目的 `dist/`。不包含单击切换录音的实验版本，不代表上游作者已验证或支持本仓库的修改。

## 豆包耳机语音桥接

- 保留的应用版本：1.1。
- 原版权声明：`Copyright (c) 2026 Doubao Headset Bridge contributors`。
- 许可证全文保留于 [apps/headset-bridge/LICENSE](apps/headset-bridge/LICENSE)。

本次公开整理保留应用源代码及属性文件，整理了构建、测试脚本和使用文档。其行为是独占匹配的音频插孔消费者接口，并在有效中间键按下时发送一次约 60 毫秒的 Fn 脉冲。

## 第三方软件

豆包语音输入法、网易 UU 远程和 macOS 是独立的第三方软件，不随本仓库分发，也不适用本仓库的 MIT 许可证。名称用于说明兼容目标，不表示其厂商参与开发、提供担保或认可本项目。
