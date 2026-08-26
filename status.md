# Yume 当前任务状态

> 当前任务：实现目录/ZIP 导入纵向切片（安全解包、检测、原子提交、资料库维护、存档迁移、受限 Web 播放器）
> 状态：已完成（静态验证通过，待 Swift 6/macOS 编译复核）
> 最后更新：2026-08-26

## 目标

- 把既有导入协调器接到真实源：目录复制与顶层 ZIP 安全解包，含动态空间预算与失败清理。
- 实现检测证据模型、确定性签名检测注册表与歧义/冲突结果，并接入 App UI 决策。
- 实现 `Games/<game-id>` 原子提交、重复游戏处理（取消/保留两份/替换保留存档）、删除策略与分离存档重挂。
- 提供存档离线导出/导入包、存储占用明细与最近游玩标记。
- 为 MV/MZ/TyranoScript 类 Web 游戏提供受限 WKWebView 播放器原型（断网、自定义 scheme 资源服务、localStorage 桥）。

## 已完成

- `CYumeZlib` C 目标：ZIP 条目流式解压（store/deflate）、CRC32 校验、大小不符即失败；经系统 zlib 链接，zlib 许可符合 ADR 边界。
- `SafeZIPExtractor`：纯 Swift 中央目录解析 + C 解压；拒绝路径逃逸、反斜杠/非 UTF-8 文件名、符号链接条目、加密条目、多卷、重复路径（大小写折叠）、超限条目数/路径长度/展开体积/压缩比；支持 ZIP64；解压失败整体回滚。
- 内置检测器：Ren'Py、RGSS1–3、MV/MZ（含 www 包装）、ONS、Kirikiri/XP3、Flash、TyranoScript 的声明式签名规则；`.dll/.pyd/.node/.tpm` 等原生组件一律阻断为 unsupported；`runtimeAvailable=false` 时同样阻断。
- `DirectoryGameImportService`：完整事务编排（验证 → 预算 → staging → 指纹查重 → 多根检测 → 歧义/重复回调裁决 → 兼容扫描 → 原子提交），错误码写入诊断日志，失败按 manifest 终态清理。
- `LocalGameStorage` 扩展：目录/ZIP 源校验与预算、staging 复制/解压、检测快照（深度 ≤4 的候选根枚举）、内容指纹（SHA-256 自研实现，路径+大小+字节流）、`Games/` 原子提交与替换（旧版移入任务内 backup，失败回滚）、`original/` 只读化及删除前可写恢复、`DetachedSaves/` 分离存档与指纹重挂、`.yumesave` 存档导出/导入（版本/游戏/引擎校验、限额、临时区原子替换）、存储明细、最近游玩标记。
- App 层：`AppModel.live()` 组合根；导入进度覆盖层、检测歧义 Sheet、重复游戏确认、成功/部分成功/失败通知；游戏详情页（启动、兼容报告、存档导出/分享/导入、按占用明细的删除流程）；设置页新增存储、控制、兼容性、诊断（本地日志查看与脱敏导出）、许可、隐私入口；四语言本地化同步补齐（142 键一致）。
- `GamePlayerView`：受限 WKWebView——`yume-game://` 自定义 scheme 只读资源服务（路径规范化、符号链接拒绝、Range 支持）、WKContentRuleList 全量断网、导航白名单、localStorage 桥（大小限额、按游戏 JSON 持久化）、虚拟方向键/确认/取消与触感反馈开关。
- 测试：检测注册表、内置检测器、SHA-256 已知向量、本地诊断往返、SafeZIP 解析/逃逸/加密/CRC 回滚、目录导入集成（原子入库、原生插件阻断关闭、大小写冲突、重复三选、替换保身份保存档、分离存档重挂、存档往返）；测试总数增至 40 个方法。
- 修复本切片内发现的缺陷：只读 `original/` 会使后续删除/staging 清理触发 EACCES，已在 `removeGame`、`discardStagingTask` 和替换备份清理前恢复可写权限。

## 当前变更文件

- `YumeCore/Package.swift`
- `YumeCore/Sources/CYumeZlib/`（新增）
- `YumeCore/Sources/YumeDomain/DetectionModels.swift`、`StorageBudget.swift`、`GameModels.swift`
- `YumeCore/Sources/YumeApplication/GameDetection.swift`、`GameImportService.swift`、`Diagnostics.swift`、`GameContentProvider.swift`、`GameSaveTransfer.swift`、`GameLibrary.swift`
- `YumeCore/Sources/YumeInfrastructure/SafeZIPExtractor.swift`、`BuiltInGameDetectors.swift`、`LocalDiagnosticStore.swift`、`SHA256Hasher.swift`、`LocalGameStorage.swift`、`InMemoryGameLibrary.swift`
- `YumeCore/Tests/YumeApplicationTests/GameDetectionTests.swift`、`ImportCoordinatorTests.swift`
- `YumeCore/Tests/YumeInfrastructureTests/BuiltInGameDetectorsTests.swift`、`DirectoryGameImportIntegrationTests.swift`、`LocalDiagnosticStoreTests.swift`、`SHA256HasherTests.swift`、`SafeZIPExtractorTests.swift`、`LocalGameStorageTests.swift`
- `YumeApp/App/AppModel.swift`、`RootView.swift`、`YumeApp.swift`
- `YumeApp/Features/Library/LibraryView.swift`、`GameDetailView.swift`（新增）、`GameItemViews.swift`
- `YumeApp/Features/Player/GamePlayerView.swift`（新增）
- `YumeApp/Features/Settings/SettingsView.swift`
- `YumeApp/Resources/{en,ja,zh-Hans,zh-Hant}.lproj/Localizable.strings`
- `ARCHITECTURE.md`、`progress.md`、`status.md`

## 关键判断

- 加密 ZIP 首版直接拒绝而非提示输密码：密码算法组件尚未过 ADR/审计门禁，先保证“明确不支持”优于半支持。
- 归档文件名仅接受 UTF-8（或纯 ASCII）：CP437/Shift-JIS 文件名留待编码识别门禁，避免静默乱码路径入库。
- 重复游戏以“引擎 + 内容指纹”为准；替换沿用原游戏 ID 与存档，keepBoth 允许同指纹两份。
- 删除游戏默认把非空存档迁入 `DetachedSaves/<game-id>/` 并记录来源 manifest；同指纹同引擎再导入时自动重挂并清除分离副本。
- Web 引擎运行时边界：MV/MZ/TyranoScript 标记 `runtimeAvailable=true` 仅代表存在受限 WKWebView 宿主，不表示任何具体游戏已验证；其余引擎在适配器落地前保持 detection-only。
- 播放器断网采用双层防护（content rule list 阻断 http/https/ws/file + 导航代理 scheme 白名单），资源只经 `yume-game://` 提供。
- `original/` 只读化属于纵深防御而非安全边界；所有删除/清理路径先恢复写权限再递归删除，避免残留半删树。

## 验证结果

- `git diff --check` 通过；全部 Swift 文件花括号/圆括号结构检查通过（含三引号字符串）。
- 四语言 Localizable.strings 键集完全一致（各 142 键），Swift 中引用的本地化键无缺失；SF Symbol 与 AppStorage 键不计入。
- ZIP 测试夹具数据用系统 zlib 独立复核：deflate 字节流与 CRC32（`0x7ede44ee`、`0x3610a686`）逐位一致。
- 敏感凭据模式扫描未发现命中；async 调用未放入 XCTest 同步 autoclosure。
- 当前 Linux 环境没有 Swift/Xcode 工具链，因此未实际运行 `swift test` 或 iOS 构建；上述结果不能视为编译通过。Xcode 工程使用 fileSystemSynchronized 组，新文件无需改 pbxproj。

## 阻塞

- 编译与运行验证仍需要 Swift 6/macOS Xcode 环境；接入更多平台无关能力不受阻，但真机行为（WebView 断网、触控、性能）无法在本环境验证。

## 唯一下一步

在 Swift 6/macOS 环境运行全部核心测试与 iPhone/iPad 构建复核，修正编译/并发问题；随后开始制作完全自有的最小合法测试夹具（先 MV/MZ），并起草 Apple 规则 4.7 预沟通材料。
