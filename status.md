# Yume 当前任务状态

> 当前任务：测试前功能开发与八引擎静态集成
> 状态：功能代码、运行时接入和离线安全边界已完成；等待 macOS/Xcode 原生构建与真机测试
> 最后更新：2026-08-28

## 已完成

- 导入 ZIP、ZipCrypto、WinZip AES、7z AES 和文件夹；统一限制路径穿越、符号链接、文件数、单文件大小与总展开量。
- 导入期识别/读取 RPA、XP3、RGSSAD、SWF/CWS、SAR/NSA，并保留原始游戏树供原生运行时直接挂载。
- 八个引擎族均已连接可执行启动路径：Ren'Py 7/8、RGSS1/2/3、RPG Maker MV/MZ、ONScripter、Kirikiri2/Z、Flash、TyranoScript。
- Web 游戏与 Ruffle 使用只读自定义 scheme、非持久 WebKit 数据仓和外部网络阻断；游戏 localStorage 映射至独立存档目录。
- 原生引擎统一通过 `CYumeRuntimeBridge` 管理创建、启动、暂停、恢复、输入、停止、事件与原生视图。
- RGSS 使用锁定的 Empo/mkxp-z、三套隔离 Ruby 对象和共享 SDL/ANGLE；支持用户导入并按游戏挂载 RTP。
- ONS/Kirikiri 使用 AetherKiri 引擎 API、CPU RGBA 宿主画面、触控/键盘输入和本地存档。
- Ren'Py 使用官方 Renios 8.5.3 与 7.8.7 两套隔离静态对象及匹配 Python 资源；保存路径固定到游戏独立目录，Python socket 在资源层禁用。
- Flash 使用内嵌 Ruffle 0.5 WebAssembly 解释器；不使用 JIT、动态下载或远程脚本。
- 游戏库、搜索/筛选、详情、封面、导入任务、删除、存档导入导出、RTP 管理、设置、四语言和虚拟控制均已接线。
- 上游源码、官方二进制来源、commit、许可证与 SHA-256 已冻结在 `ThirdParty/RuntimeDependencies.lock.json`；许可证入口见 `LICENSE` 与 `NOTICE.md`。

## 自动验证

- Swift 包共 111 个测试通过，覆盖检测、导入、归档安全、存储、启动计划、会话与原生 ABI。
- 全部 App/Core Swift 源文件通过 Swift 6 前端语法解析。
- 四语言本地化键集合一致；运行时关键资源存在；依赖锁 JSON、Shell 语法、工程文件解析及 `git diff --check` 通过。
- `Scripts/verify_pretest.sh` 可离线重复执行上述测试前门禁。
- Xcode 构建阶段会校验并暂存 mkxp-z 官方固定产物，构建 AetherKiri，将 Ren'Py 双代静态库按官方依赖顺序合并为只暴露各自入口的 arm64 对象，并逐件校验架构和宿主所需符号。

## 仍需在测试阶段验证

- 当前开发环境为 Linux，无法执行 Xcode iOS 链接、代码签名、模拟器或真机运行；这不再是功能代码缺口，而是下一阶段的平台验证。
- 首次 macOS 构建会按锁文件下载约 3 组固定原生产物并从源码构建 AetherKiri，耗时和磁盘占用会明显高于普通 Swift 构建。
- 真机需要逐引擎用合法自有游戏样本验证首帧、音视频、输入、旋转、暂停恢复、存档、峰值内存和退出行为。RGSS/Ren'Py 的嵌入式解释器具有进程级全局状态，跨游戏测试应为每个样本重新启动 App。

## 测试入口

1. 在仓库根目录执行 `Scripts/verify_pretest.sh`。
2. 使用 Xcode 26 打开 `Yume.xcodeproj`，选择 arm64 iOS 18+ 设备进行 Debug 构建。
3. 按 Ren'Py 7、Ren'Py 8、RGSS1、RGSS2、RGSS3、MV、MZ、ONS、Kirikiri2/Z、SWF、Tyrano 的顺序执行合法样本矩阵。
