# Yume

Yume 是一个面向 iPhone 和 iPad 的开源、本地多引擎视觉小说与 RPG 兼容运行器。游戏由用户从“文件”App 导入，识别、解包、运行和存档均在设备本地完成。

## 当前引擎范围

- Ren'Py 7 / 8
- RPG Maker XP / VX / VX Ace（RGSS1–3）
- RPG Maker MV / MZ
- ONScripter / NScripter
- Kirikiri 2 / Kirikiri Z（XP3）
- TyranoScript
- Flash（Ruffle，无 JIT）
- Artemis（ASB / IET / PFS，实验性）

兼容性以实际游戏版本、资源格式和插件为准。Yume 不执行 Windows EXE、DLL、Node 原生模块或游戏附带的原生插件，也不支持 DRM、自定义加密或需要联网验证的内容。

## 项目原则

- 完全离线，无账号、无遥测、无游戏下载入口。
- 不内置商业游戏、RTP、密钥、破解补丁或受版权保护的游戏素材。
- 所有运行时随源码固定并静态构建，不下载引擎、不使用 JIT。
- 导入内容复制到 App 容器；原始文件与存档不会被静默覆盖。
- 项目不面向 App Store / TestFlight，主要用于自建签名、研究和社区侧载。

## 构建

要求 macOS、Xcode 26、iOS 18 SDK、Swift 6、CMake 3.28+、Ninja，以及构建脚本中列出的原生工具链。

```bash
Scripts/verify_pretest.sh

xcodebuild \
  -project Yume.xcodeproj \
  -scheme Yume \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build
```

首次构建会准备体积较大的原生依赖。仓库也提供手动触发的 GitHub Actions 工作流，用于生成未签名 arm64 IPA。

## 测试

```bash
Scripts/verify_pretest.sh
swift test --package-path YumeCore
```

原生引擎最终仍需在真机上用有合法使用权的最小样本验证：启动、首帧、输入、音频、存档、前后台切换和退出。

## 法律与内容边界

Yume 只提供兼容运行能力。请仅导入自己有权使用的游戏和运行时资源。各第三方组件保留其原许可证，许可证原文位于对应 `ThirdParty` 源码目录，并在 App 的开源许可页面展示。

## 许可证

Yume 自有代码按 AGPL-3.0-or-later 发布；第三方组件按各自许可证发布。依赖版本、源码地址和固定提交记录在 `ThirdParty/RuntimeDependencies.lock.json`。
