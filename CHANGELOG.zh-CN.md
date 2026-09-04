# 更新日志

[English](CHANGELOG.md)

## [未发布]

## [1.0.3] - 2026-09-03

- 修复 macOS 15.0–15.1 设备启动闪退
- 修复个别设备非圆角图标问题
- 优化插件注入：
  - 直接拖入 DEB 时不再拦截带安装脚本的 DEB
  - 修复注入时错误乱改系统库、拖慢进程

## [1.0.2] - 2026-08-31

- IPA 注入「自动修改越狱依赖」功能优化
- 修复直接导入抖音 IPA 提取头文件时进程文件处理错误
- 优化页面 UI，改善用户体验

## [1.0.1] - 2026-08-29

`v1.0.0-beta.4` 之后的首个正式版。ad-hoc 签名，未经苹果公证。

- 注入在工作台完成。IPA、插件、证书和描述文件可一并选择。插件默认注入主程序，ProtobufLite 需单独指定。
- 签名可选：不签名、Apple ID 或 P12。成套的 p12 与描述文件使用证书签名。密码明文显示，默认为 `1`。手机 IPA 使用 zsign，Mac 应用仍使用 `codesign`。
- 输出为原 IPA 同目录下的 `*.injected.ipa`。
- 可修改显示名、包名和版本，开启文件共享，移除 URL Scheme，以及删除 Watch、插件和 App Clip。
- 微信 IPA 会单独修复深色图标。
- 内存页与首页数据与活动监视器一致。
- 清理页不再将无法访问的目录显示为空。
- 已移除 App Store 下载。安装、解包、注入和重签保留。

首次打开若被拦截：系统设置 → 隐私与安全性 → 仍要打开。见 [中文 README](docs/README.zh-CN.md#首次打开被拦截)。

更早的测试版说明见 [英文 Changelog](CHANGELOG.md)。

[1.0.3]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.3
[1.0.2]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.2
[1.0.1]: https://github.com/iosrxwy/MacAssistant/releases/tag/v1.0.1
