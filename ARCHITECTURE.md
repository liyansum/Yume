# Yume 技术架构

> 文档状态：开发架构基线
> 最后更新：2026-08-26  
> 当前实现状态：SwiftUI 宿主、目录/ZIP 导入管线（安全解包、检测、原子提交、重复处理）、资料库持久化与维护、存档离线迁移、本地诊断和受限 Web 播放器已有开发版实现；7z、转换管线、索引数据库与各引擎运行时适配器仍是计划能力
> 约束优先级：若本文与 `Agents.md` 冲突，以 `Agents.md` 为准

## 1. 新会话快速入口

Yume 是最低支持 iOS/iPadOS 18 的完全离线、本地多引擎游戏兼容运行器。用户导入自己合法持有的 ZIP、7z 或游戏目录；App 在本地完成安全解包、引擎识别、兼容性检查、必要的非破坏性转换和运行。

首版目标包括 Ren'Py 7/8、RGSS1/2/3、RPG Maker MV/MZ、ONS、Kirikiri 2/Z、Flash AVM1/AVM2 和 TyranoScript v4/v5。所有运行时必须随 App 静态提交，不下载新引擎，不执行 EXE/DLL，不加载游戏携带的原生插件，不使用 JIT，不联网。

新 Codex 会话按以下顺序建立上下文：

1. `Agents.md`：不可违反的产品、许可、安全和发布约束，以及完整决策档案。
2. `ARCHITECTURE.md`：系统结构、依赖方向、数据流和预期代码导航。
3. `progress.md`：项目总体里程碑和长期门禁。
4. `status.md`：当前单项任务、改动文件、阻塞与下一步。

不要通过重读 `Agents.md` 第 13 节全部历史档案来判断当前任务；先读其正文、本文和两份状态文件，只有遇到具体决策争议时再定位相应 ADR。

## 2. 架构目标

- 在一个原生 iPhone/iPad App 中承载多个彼此隔离的静态引擎兼容层。
- 把不可信游戏数据与系统能力隔开，只暴露受限、可审计的宿主接口。
- 保证导入、转换和清理可取消、可恢复、可解释，不损坏用户原件或存档。
- 让 UI、共享基础设施和各引擎适配器可以独立测试与演进。
- 在最低支持设备上对磁盘、内存、线程、日志和运行会话实施统一预算。
- 保持完全离线、无账号、无遥测，不用网络服务补齐本地能力。

## 3. 系统全景

```text
用户文件 / ZIP / 7z
         │
         ▼
┌──────────────────────────────────────────────────────────────┐
│ SwiftUI App Shell                                            │
│ 游戏库 · 导入任务 · 游戏详情/播放器 · 设置/关于 · 本地诊断 │
└──────────────────────────────┬───────────────────────────────┘
                               │ 调用用例
┌──────────────────────────────▼───────────────────────────────┐
│ Application                                                  │
│ ImportCoordinator · LibraryService · CompatibilityService    │
│ PlaySessionCoordinator · SettingsService                     │
└───────────────┬──────────────────────────────┬───────────────┘
                │                              │
┌───────────────▼────────────────┐  ┌──────────▼───────────────┐
│ Core / Infrastructure          │  │ Engine Host              │
│ 安全归档、检测、转换、存储     │  │ VFS、渲染、音频、输入、  │
│ 媒体、编码、日志、资源预算     │  │ 存档、时钟、事件、日志    │
└───────────────┬────────────────┘  └──────────┬───────────────┘
                │                              │ 稳定 Swift/C ABI
                │                    ┌─────────▼────────────────┐
                │                    │ Static Engine Adapters   │
                │                    │ RenPy / RGSS / MV-MZ     │
                │                    │ ONS / Kirikiri / Flash   │
                │                    │ TyranoScript             │
                │                    └──────────────────────────┘
                ▼
        App 私有容器与本地索引
```

这是单 App、单进程架构。所谓引擎隔离是模块、ABI、状态、目录、队列和资源生命周期隔离，并非进程安全沙箱。任一底层解析器失败都有可能影响整个进程，因此二进制输入验证和资源上限属于架构要求。

## 4. 分层与依赖规则

| 层 | 职责 | 可以依赖 | 禁止事项 |
| --- | --- | --- | --- |
| Presentation | SwiftUI 导航、资料库、导入进度、播放器覆盖层、设置、诊断 | Application、只读展示模型 | 直接操作归档、数据库或引擎全局对象 |
| Application | 编排用例、状态机、取消/恢复、用户确认、会话生命周期 | Domain 协议 | 包含引擎专有解析逻辑 |
| Domain | 游戏、任务、兼容报告、配方、资源预算等稳定模型与协议 | Foundation 中必要的值类型 | 依赖 SwiftUI、WebKit 或具体数据库 |
| Infrastructure | 文件、归档、哈希、索引、媒体、编码、日志的协议实现 | Domain、Apple 系统框架、已审计静态依赖 | 反向调用 UI 或绕过任务状态机写资料库 |
| EngineHost | 给引擎提供受限 VFS、存档、渲染、音频、输入、时钟与日志 | Domain/Core 协议 | 暴露任意容器路径、网络或通用原生桥 |
| EngineAdapters | 逐引擎探测、准备、运行及兼容报告 | EngineHost、对应静态运行时 | 相互依赖、直接访问 App 单例、动态加载代码 |

依赖方向始终指向稳定协议。具体归档库、数据库、渲染后端或引擎运行时通过组合根注入，不能在界面和业务用例中散落静态单例。

## 5. 当前工程与目标模块布局

当前工程采用一个 iOS App target 加仓库内本地 Swift Package。真实入口如下：

- [`Yume.xcodeproj`](Yume.xcodeproj)：iOS/iPadOS 18+ App 工程与共享 Scheme（Swift 6 + 完全并发检查）。
- [`YumeApp/App`](YumeApp/App)：App 入口、依赖组合和 iPhone/iPad 自适应根导航。
- [`YumeApp/Features`](YumeApp/Features)：已落地资料库（含导入进度、检测歧义与重复游戏处理）、游戏详情（存档迁移、删除策略）与设置（存储、控制、兼容性、诊断、许可、隐私、关于）；播放器见 `Features/Player`。
- [`YumeApp/Resources`](YumeApp/Resources)：自有颜色资源及简体中文、繁体中文、英语、日语本地化。
- [`YumeCore`](YumeCore)：本地 Swift Package；提供 `CYumeZlib`（自研 zlib 封装的 C 目标，链接系统 zlib）与 `YumeDomain`、`YumeApplication`、`YumeInfrastructure`、`YumeEngineHost` 四个静态模块及核心单元测试。

当前代码布局与后续目标如下；标注“计划”的目录尚不存在：

```text
Yume.xcodeproj/
YumeApp/
├── App/                         # 已实现：入口、组合根（AppModel.live()）、自适应导航
├── Features/
│   ├── Library/                 # 已实现：网格/列表、搜索排序、详情、删除、存档迁移
│   │                            # 已实现：文件选择导入入口与导入覆盖层（Import 未单独建目录）
│   ├── Settings/                # 已实现：设置导航与关于/法律基础文案、诊断页
│   ├── Player/                  # 已实现：受限 WKWebView 播放器、虚拟控制、本地存储桥
│   └── Diagnostics/             # 计划：开发版详细诊断独立页（当前并入 Settings）
└── Resources/                   # 本地化和权利清楚的 App 自有资源
YumeCore/
├── Sources/
│   ├── CYumeZlib/               # 已实现：ZIP 条目流式解压 + CRC 校验的 C 接口
│   ├── YumeDomain/              # 已实现：游戏、引擎、导入状态机、staging manifest、检测证据、预算等值类型
│   ├── YumeApplication/         # 已实现：资料库查询、导入协调器、导入服务、检测注册表协议、诊断协议、存档迁移协议
│   ├── YumeInfrastructure/      # 已实现：内存资料库、安全存储、SafeZIPExtractor、内置检测器、SHA-256、本地诊断存储
│   └── YumeEngineHost/          # 已实现首版宿主协议骨架
├── Tests/                       # 已实现领域、应用、基础设施单元测试与目录导入集成测试
└── Package.swift
EngineAdapters/                  # 计划；通过对应门禁后逐项创建
│   ├── RenPyLegacy/             # 7.x 兼容带
│   ├── RenPyModern/             # 8.x 兼容带
│   ├── RGSS/                    # XP/VX/VX Ace
│   ├── RMMV/                    # WKWebView 宿主
│   ├── RMMZ/
│   ├── ONS/
│   ├── Kirikiri/
│   ├── Flash/
│   └── TyranoScript/
```

优先使用一个 App target 加本地 Swift Package/静态库划分模块，避免为形式上的模块化增加动态 framework。C/C++/Objective-C++ 运行时通过窄 C ABI 接入；符号默认隐藏，冲突时使用构建期前缀或经过验证的统一版本。

## 6. 核心模型和协议

核心模型应是可持久化、可测试、可跨层传递的值类型：

- `GameID`、`ImportedGame`、`EngineID`、`EngineDescriptor`
- `ImportTaskID`、`ImportState`、`ImportCheckpoint`
- `ProbeEvidence`、`ProbeResult`、`CompatibilityReport`
- `ConversionRecipe`、`ConversionStep`、`ConversionManifest`
- `StorageBudget`、`ResourceBudget`
- `SaveDescriptor`、`ControlProfile`
- `EngineEvent`、`SessionState`、`DiagnosticID`

当前已实现 `GameID`、`ImportedGame`（含 `contentFingerprint`）、`EngineID`、`EngineDescriptor`、`ImportTaskID`、`ImportState`、`StorageRelativePath`、`StagingManifest`、`DetectionEvidence`、`ProbeResult`、`CompatibilityReport`、`GameManifest`、`StorageBudget`、`DiagnosticEntry` 与首版 `EngineEvent`/宿主骨架；其余条目仍是计划模型。

检测协议已按“检测器与运行适配器分离”落地：`DetectionSnapshot` 提供大小写/分隔符归一化的只读文件清单，`DetectorRegistry.decide` 返回 `selected/ambiguous/noMatch`，`SignatureGameDetector` 用声明式规则（必需/佐证/阻断扩展名）产出证据与兼容报告。运行时可用性由 `GameEngineCatalog` 从检测器的 `runtimeAvailable` 派生为 `detectionOnly/restrictedWeb/dedicatedRuntime` 三类宿主策略；新增引擎适配器时只需注册新检测器并在目录中声明宿主形态。

宿主协议保持小而稳定，概念接口如下；实际签名可在首条纵向切片中校正：

```swift
protocol GameDetector: Sendable {
    var engineID: EngineID { get }
    func probe(_ source: DetectionSource) async throws -> ProbeResult
}

protocol GameEngineAdapter: Sendable {
    var descriptor: EngineDescriptor { get }
    func prepare(game: ImportedGame, context: EngineContext) async throws -> PreparedGame
    @MainActor func makePlayer(for game: PreparedGame, context: EngineContext) throws -> EnginePlayer
}

protocol EnginePlayer: AnyObject {
    var events: AsyncStream<EngineEvent> { get }
    func start() async throws
    func pause()
    func resume()
    func stop() async
}
```

检测器与运行适配器分开注册：导入扫描不应为了判断游戏类型而初始化大型运行时。`EngineContext` 只提供虚拟文件系统、该游戏存档目录、安全媒体、渲染目标、音频、输入、时钟和结构化日志。

## 7. 关键数据流

### 7.1 导入事务

```text
picked
  → validatingSource
  → budgeting
  → copyingToStaging / extractingToStaging
  → detectingRoots
  → resolvingAmbiguity
  → scanningCompatibility
  → awaitingConversionConsent（仅需要时）
  → convertingDerivedData
  → validatingCommit
  → committed
```

原子提交前任一阶段可进入 `paused`、`cancelled` 或 `failed`；已进入 `committed` 后只能暂停核对或完成。只有 `validatingCommit` 成功后才能将同卷 staging 原子移动到正式资料库；失败、取消或空间不足时只按任务 manifest 清理本任务未提交文件。App 被终止后依据 checkpoint 恢复，无法证明安全时执行有边界的清理。

当前已实现纯 `ImportStateMachine` 与 actor `ImportCoordinator`：合法分支由显式邻接规则控制，重复 pause/resume/同阶段推进不重复写 checkpoint；取消、失败和完成先持久化终态再幂等清理 staging。启动发现 active 任务时先写为同阶段 paused，调用方重新验证输入、空间和配方后才能 resume；损坏 manifest、checkpoint 写入失败或终态清理失败逐任务报告并保留数据。`committed` 表示已经越过原子提交点，此后禁止普通取消/失败，只能暂停核对后完成，避免把已提交游戏当作未提交数据处理。

在协调器之上，actor `DirectoryGameImportService` 已把目录与 ZIP 源接入完整事务：验证源 → 动态空间预算（含 `max(2 GiB, 容量 5%)`、上限 10 GiB 的安全预留）→ staging 复制/安全解压 → 内容指纹查重 → 多候选根检测 → 歧义与重复游戏由 UI 决策回调裁决 → 兼容扫描 → 原子提交资料库。加密 ZIP 当前直接拒绝，7z 等待组件选型门禁。

只自动展开用户选择的顶层 ZIP/7z，不递归展开其中的通用归档。一个归档发现多个游戏根目录时，每个候选形成独立提交单元。

### 7.2 运行会话

```text
选择游戏 → 校验 manifest/派生版本 → 创建只读 VFS
→ 装配单游戏存档与控制布局 → adapter.prepare
→ 创建唯一 EnginePlayer → running ↔ paused → stopping → released
```

`PlaySessionCoordinator` 保证同一时间只有一个活跃游戏：启动前依次校验游戏存在、兼容状态可运行、引擎在 `GameEngineCatalog` 中具备真实运行时（检测只读引擎在访问内容前即被拒绝），停止时返回会话归属的游戏 ID 供宿主记录最近游玩。停止必须释放渲染、纹理、音频、计时器、WebView/解释器状态和输入监听，再恢复系统音频及方向策略。锁屏、后台和音频中断默认暂停；首版不后台持续运行。

### 7.3 存档与离线导入导出

引擎只能读写自己的虚拟存档根。导出由宿主生成仅包含存档与版本元数据的本地包；导入先在临时区验证游戏 ID、引擎/格式版本和路径，再原子替换或合并。游戏本体、密钥、日志和缓存不得混入存档包。

## 8. 本地数据架构

```text
Application Support/Yume/
├── Games/<game-id>/
│   ├── original/                # 已实现：导入后只读的不可变副本
│   ├── derived/                 # 已创建；转换结果仍为计划能力
│   ├── saves/                   # 已实现：含 localStorage 桥与 .yumesave 离线迁移
│   ├── manifest.json            # 已实现：检测证据、内容根、格式版本
│   └── logs/                    # 已创建；按游戏滚动日志仍为计划能力
├── Staging/<task-id>/           # 已实现：manifest + content/<task 内容>
├── DetachedSaves/<game-id>/     # 已实现：删除游戏时保留的存档与来源 manifest
├── Cache/                       # 已实现：存档导出/导入事务临时区
├── Diagnostics/                 # 已实现：本地 JSONL 诊断日志与导出
└── Library.sqlite               # 计划；当前以目录扫描 + manifest 为真相来源
```

当前 `LocalGameStorage` 已实现固定根目录创建、对 staging/缓存/诊断的选择性备份排除、iOS 文件保护、任务发现、manifest 原子写入、相对路径验证、符号链接拒绝和按强类型任务 ID 的幂等 staging 清理。它同时实现了 `Games/<game-id>` 的原子提交（含同卷移动、替换旧版时保留存档与身份）、`original/` 只读化及删除/清理前的可写恢复、按内容指纹的重复检测与分离存档（`DetachedSaves/`）重挂、存储占用明细与最近游玩标记。`contentLocation` 只负责定位内容根并校验入口文件，不再内置引擎白名单；运行时可用性统一由 `GameEngineCatalog`（从检测注册表派生的宿主策略，唯一允许携带引擎 ID 策略的位置）与 actor `PlaySessionCoordinator`（独占会话 + 检测只读引擎拒绝启动）在 Application 层判定。资料库仍以目录扫描为真相来源，SQLite/SwiftData 索引与容量预算执行仍是计划能力。

数据所有权规则：

| 数据 | 是否可重建 | 自动清理 | 备份策略 |
| --- | --- | --- | --- |
| `original/` | 否 | 永不 | 排除设备备份；用户外部源不受影响 |
| `derived/` | 是 | 低空间时仍需先询问 | 排除设备备份 |
| `saves/` | 否 | 永不 | 可进入用户启用的加密设备备份；支持离线导入/导出 |
| `Staging/` | 不适用 | 失败、取消或不可恢复时立即清理 | 不备份 |
| `Cache/` | 是 | 可以 | 不备份 |
| 索引数据库 | 可由 manifest 重建 | 损坏时重建 | 不是游戏数据唯一真相来源 |

空间预算初始保留 `max(2 GiB, 设备容量的 5%)`，最高 10 GiB，最终参数以最低设备真机压力测试校准。游戏数量、单游戏和资料库容量不设固定产品上限，但安全文件数、路径、压缩比、耗时和内存阈值必须存在且用户不能关闭。

## 9. 引擎接入策略

| 适配器 | 运行路径 | 首版边界 |
| --- | --- | --- |
| RenPyLegacy | 静态 Python 2 兼容运行时与受限宿主 | 7.x；不支持 6.x、原生 Python 扩展 |
| RenPyModern | 静态 Python 3 兼容运行时与受限宿主 | 8.x；精确小版本由夹具矩阵决定 |
| RGSS | 独立 RGSS1/2/3 与 Ruby 语义兼容层 | XP/VX/VX Ace；资源须完整；Win32API 仅静态白名单 shim |
| RMMV/RMMZ | `WKWebView`、只读本地资源映射和窄原生桥 | 纯 JS 插件、受限 CommonJS/NW.js/Node shim；无真实 Node/NW.js/原生插件 |
| ONS | 独立脚本、资源和文本兼容层 | 标准 `txt`/`dat` 与经验证 NSA/SAR/NS2/NS3；无 `nt2`/`nt3` |
| Kirikiri | 独立 TJS/KAG 与标准 XP3 兼容层 | Kirikiri 2/Z；无自定义加密、过滤器、`.tpm`/原生插件 |
| Flash | 独立 SWF 解析、AVM1/AVM2 解释与渲染层 | AS1/2/3、FWS/CWS/ZWS；无 JIT、Stage3D、AIR/ANE、DRM、网络/隐私硬件 |
| TyranoScript | `WKWebView` 与受限 Tyrano/KAG/JS shim | 浏览器导出 v4/v5；无 Electron/NW.js/Node 原生能力 |

每个适配器拥有自己的 descriptor、检测证据、兼容矩阵、资源预算、错误映射、夹具和回归测试。共享层不得出现按商业游戏名称匹配的补丁。

## 10. 并发与生命周期

- 使用 Swift structured concurrency；长任务必须支持取消并在阶段边界保存 checkpoint。
- `ImportCoordinator` 串行调度解包/转换重任务，其他重任务排队；轻量头部和元数据探测可受控并发。
- 资料库索引与 manifest 提交由单一 actor/事务边界协调，禁止多个服务直接竞争写目录。
- UI 状态在 `MainActor` 更新；归档、哈希、检测和转换不得占用主线程。
- `PlaySessionCoordinator` 独占运行会话；引擎回调转为类型化 `EngineEvent`，不得直接修改 SwiftUI 状态。
- 每个任务和会话都有稳定 ID，用于取消、恢复、资源核算和日志关联。

## 11. 安全边界

- 所有归档、脚本、图片、字体、音视频和存档均视为不可信输入。
- 文件访问必须经过规范化的虚拟路径；拒绝绝对路径、`..`、符号/硬链接逃逸、设备文件和大小写碰撞。
- 脚本宿主不提供网络、进程、任意文件、反射、通用 FFI、隐私硬件或任意 iOS API。
- `WKWebView` 默认阻止外部导航、网络请求和非白名单 URL scheme；消息桥使用有限的类型化命令。
- 不执行 `.exe`，不加载 `.dll`、`.dylib`、`.framework`、`.node`、ANE、ActiveX 或游戏携带的其他原生代码。
- 不实现 DRM 绕过、自定义加密破解或密钥获取。
- 密码只存在于当前导入任务内存，不写 Keychain、磁盘、manifest 或日志。
- 原生/C/C++ 解析器要求边界检查、fuzz、安全回归和资源 watchdog。

## 12. 日志与可观测性

系统完全离线，因此可观测性只写本机：

- 结构化字段至少包括时间、级别、子系统、任务/会话 ID、引擎版本、阶段、耗时、状态转换、资源预算、错误链和清理结果。
- 不记录密码、完整路径、完整脚本文本、存档正文或个人数据；路径使用容器相对路径或哈希。
- 每游戏最多 20 MB、最多 7 天，全 App 200 MB 硬上限，滚动删除最旧日志。
- 开发构建提供开发者诊断页，可查看日志、任务 manifest、资源预算和本地导出。
- Release 只保留普通诊断入口和必要级别，不上传崩溃或遥测。

## 13. 测试架构

测试按层组织：

- Domain/Application 单元测试：状态机、预算、冲突处理和错误映射。
- Infrastructure 集成测试：归档、路径、编码、原子提交、恢复与清理。
- Security 测试：ZIP Slip、压缩炸弹、损坏头、极长路径、链接逃逸、模糊测试和低存储。
- Adapter contract 测试：每个引擎必须通过同一套启动、暂停、停止、输入、存档和资源释放契约。
- Engine fixture 测试：合法夹具的检测证据、golden frame、音频事件、脚本流程和存档往返。
- Device 测试：最低 iOS/iPadOS 18 设备及当前设备的首帧、峰值内存、发热、后台恢复和控制器行为。

夹具先于对应引擎实现。夹具清单必须记录来源、权利、哈希、覆盖能力和是否允许仓库、CI、审核演示及公开分发。

## 14. 构建、依赖与发布边界

- 优先 Apple 系统框架和自有实现；系统外组件只允许经过审计的宽松或商业许可证静态依赖。
- 首版排除 GPL、LGPL、AGPL、MPL、EPL 及其他产生 copyleft、替换/重新链接或类似传递义务的组件。
- 新依赖必须先记录 ADR、固定版本/commit、许可证原文、传递依赖、SBOM、安全记录、包体、最低系统和退出方案。
- 不创建运行时插件目录、远程配置或引擎下载机制。
- 首个全链路原型后再根据实测制定包体阈值；不能用按需下载引擎解决超限。
- 所有首版引擎达到合法样本、兼容矩阵、安全、许可、性能和审核材料门槛后才可上架。

目前尚未确定的实现选择包括 ZIP/7z 具体静态组件、索引采用 SQLite 封装还是 SwiftData、各语言运行时的最终构建方案，以及渲染共享程度。这些选择必须经原型与许可证审计后更新本文，不能由文档示例提前锁死。

## 15. 实施顺序与当前切片

1. 为目标引擎制作合法最小夹具，并准备 Apple 规则 4.7 预沟通材料。
2. 创建 App/Domain/Application/Infrastructure/EngineHost 骨架和本地诊断。已完成：宿主骨架、导入事务（安全 ZIP 解包、检测、预算、原子提交、恢复）、资料库持久化与维护、存档离线迁移、本地诊断和受限 Web 播放器原型。
3. 用 MV/MZ 完成第一条纵向切片：ZIP/7z 导入、检测、兼容报告、WKWebView 启动、输入、存档、退出和诊断。开发版已打通 MV/MZ/Tyrano 目录与 ZIP 导入到 WKWebView 运行、localStorage 存档桥和退出；7z、转换管线与合法夹具验证仍缺，不得据此宣称支持任何引擎。
4. 固化安全归档、编码、转换 manifest、恢复和磁盘清理机制。安全 ZIP 已落地（路径逃逸/符号链接/压缩炸弹/加密拒绝、ZIP64、CRC 校验）；7z 与编码确认待组件选型门禁。
5. 每次接入一个引擎适配器，并先完成其许可审计、夹具和兼容矩阵。
6. 全引擎达到发布门槛后进入外部 TestFlight 和上架准备。

截至 2026-08-26，步骤 2 已完成开发版实现；步骤 3 的 Web 引擎链路已有可编译目标但未经真机验证，且所有引擎兼容实现仍受“夹具先于实现”与规则 4.7 预沟通门禁约束。

## 16. 架构维护规则

- 新增、删除或重命名顶层模块、关键协议、持久化结构或核心数据流时同步更新本文。
- 架构发生不可逆或跨模块决策时，先在 `Agents.md` 的决策档案中记录，再更新本文的当前结论。
- 本文描述真实结构；工程创建后必须把“预期布局”更新成实际路径，并为关键入口提供相对链接。
- `progress.md` 只记录里程碑状态，`status.md` 只记录当前任务，详细技术结构不重复粘贴到两者。
- 未实现内容必须保留“计划”“目标”或“待验证”标记，禁止让后续 Codex 误认为代码已经存在。
