# Yume 当前任务状态

> 当前任务：多引擎格式读取层（XP3/RPA/SWF/SAR-NSA/脚本扫描）+ App 外壳补全（任务中心、开发者诊断、播放挂起）
> 状态：已完成（静态验证通过，待 Swift 6/macOS 编译复核）
> 最后更新：2026-08-26

## 目标

- 为每个首版引擎族落地标准未加密载体的只读格式读取器，作为未来适配器探测/准备阶段的基础。
- 补全 App 外壳：恢复任务只读入口（ADR-0040 导航栏进度入口）、开发构建诊断页、后台媒体挂起。

## 已完成

- `CYumeZlib` 新增 `yume_zlib_inflate_to_file`：通用 zlib 流解压到文件，输出大小与 adler32 尾校验。
- `KirikiriXP3Archive`：经典/变体双魔数识别、TOC 压缩表解析（adler+tag+size 记录链）、info/file 段组合成条目、UTF-16LE 名称、路径归一与大小写查重、受保护条目拒绝提取、未压缩条目流式提取；压缩条目当前明确拒绝（`compressedEntryUnsupported`）。
- `RenPyRPAArchive`：RPA-1.0/2.0/3.0 头解析（十六进制偏移+密钥）、最小 cPickle 子集解码器（protocol/frame/memoize/binput/mark/tuple/list/dict/appends/setitems/text/int/binfloat/stop），名称按标量异或还原；2 字段与 3 字段（含 prefix）元组均支持。
- `SWFFileParser`：FWS 全量解析（RECT 位读取器、帧率/帧数、tag 遍历上限 512）；CWS 仅头部（压缩体待后续 zlib 接入）；ZWS 明确 `lzmaUnsupported`；未知签名失败关闭。
- `NScripterArchive`（子代理产出）：SAR/NSA/NS2 未加密目录（大端、16 字节定长名、高位压缩标志剥离）、越界双重校验、仅未压缩条目可提取；`NScripterScriptScanner`：UTF-8 严格解码的脚本只读统计（命令计数、非 ASCII 报告），不执行不解密。
- App 外壳（子代理产出）：`AppModel` 暴露 recoveredTasks/diagnosticEntries/isPlaybackSuspend 状态；`ImportTaskCenterView` 只读任务中心（11 个 ImportStage 本地化标签）经 LibraryView 工具栏条件入口进入；`DeveloperDiagnosticsView`（整体 #if DEBUG）展示最近日志与引擎目录表，Settings 增加调试专用入口；播放器响应 scenePhase 进入后台暂停媒体（原生 API + JS 兜底）并显示恢复浮层；`.gitignore` 的运行时目录规则锚定为根目录避免误忽略源码目录。
- 四语言本地化同步至各 170 键，完全配对。

## 当前变更文件

- `YumeCore/Sources/CYumeZlib/include/CYumeZlib.h`、`CYumeZlib.c`
- `YumeCore/Sources/YumeInfrastructure/KirikiriXP3Archive.swift`、`RenPyRPAArchive.swift`、`SWFFile.swift`（均新增）
- `YumeCore/Sources/YumeInfrastructure/NScripterArchive.swift`、`NScripterScriptScanner.swift`（新增）
- `YumeCore/Tests/YumeInfrastructureTests/KirikiriXP3ArchiveTests.swift`、`RenPyRPAArchiveTests.swift`、`SWFFileTests.swift`（新增）
- `YumeCore/Tests/YumeInfrastructureTests/NScripterArchiveTests.swift`、`NScripterScriptScannerTests.swift`（新增）
- `YumeApp/App/AppModel.swift`、`RootView.swift`
- `YumeApp/Features/Library/LibraryView.swift`、`Player/GamePlayerView.swift`、`Settings/SettingsView.swift`
- `YumeApp/Features/Import/ImportTaskCenterView.swift`、`Diagnostics/DeveloperDiagnosticsView.swift`（新增）
- `YumeApp/Resources/{en,ja,zh-Hans,zh-Hant}.lproj/Localizable.strings`
- `.gitignore`、`ARCHITECTURE.md`、`progress.md`、`status.md`

## 关键判断

- 格式读取器全部“标准未加密优先”：压缩 XP3 条目、ONS 自定义压缩、ZWS/LZMA 一律明确报不支持，不做任何解密或猜测式兼容；这符合“自定义加密暂不支持”的既定边界。
- RPA pickle 解码只实现 Ren'Py 实际使用的最小操作码集，未知操作码立即 `invalidArchive`；真实 Ren'Py 索引需在 macOS 上用合法夹具回归后再视为可用。
- SWF 的 CWS 压缩体复用现有 inflate 能力是后续小步改造（需把 C 函数改为内存接口），本次先保证头信息与失败关闭语义正确。
- 后台挂起采用“原生 pauseAllMediaPlayback + JS 兜底”双层策略；不自动恢复，由用户点击，符合“锁屏/后台默认暂停且不承诺后台持续运行”的产品边界。
- 任务中心为只读恢复视图，不提供 resume 操作——resume 需重新验证输入/空间/配方版本，属后续导入会话功能。

## 验证结果

- 全部 Swift 文件花括号/圆括号结构检查通过（修复一处 `Set<String]` 笔误）；`git diff --check` 通过。
- 四语言 Localizable.strings 键集完全一致（各 170 键），新增键均在代码中引用。
- 敏感凭据模式扫描未发现命中；无注释、无 TODO、无版权素材嵌入。
- 子代理并行开发中 2 个（XP3/RPA-SWF）返回空产出，已由主会话直接实现并补齐测试。
- 当前 Linux 环境没有 Swift/Xcode 工具链，未实际运行 `swift test` 或 iOS 构建；上述结果不能视为编译通过。合成 fixture（手写 stored-deflate + adler32、手写大端 SAR、手写 FWS 位流）逻辑未经真机验证。

## 阻塞

- 编译与运行验证仍需要 Swift 6/macOS Xcode 环境；格式读取器对真实游戏文件的兼容性结论必须等合法夹具到位后建立。

## 唯一下一步

在 Swift 6/macOS 环境运行全部核心测试与 iPhone/iPad 构建复核并修正问题；随后按负责人排期继续多引擎宿主推进（CWS 内存解压接入、适配器探测契约、转换管线骨架）。
