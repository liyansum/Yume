# Yume 技术架构

> 文档状态：开发架构基线
> 最后更新：2026-08-26  
> 当前实现状态：首个 SwiftUI 宿主骨架与核心模块已落地；存储、完整导入、诊断、播放器和引擎适配器仍是计划能力
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

- [`Yume.xcodeproj`](Yume.xcodeproj)：iOS/iPadOS 18+ App 工程与共享 Scheme。
- [`YumeApp/App`](YumeApp/App)：App 入口、依赖组合和 iPhone/iPad 自适应根导航。
- [`YumeApp/Features`](YumeApp/Features)：已落地资料库与设置界面；Import、Player、Diagnostics 待后续切片创建。
- [`YumeApp/Resources`](YumeApp/Resources)：自有颜色资源及简体中文、繁体中文、英语、日语本地化。
- [`YumeCore`](YumeCore)：本地 Swift Package；当前提供 `YumeDomain`、`YumeApplication`、`YumeInfrastructure`、`YumeEngineHost` 四个静态模块及核心单元测试。

当前代码布局与后续目标如下；标注“计划”的目录尚不存在：

```text
Yume.xcodeproj/
YumeApp/
├── App/                         # App 入口、组合根、自适应导航
├── Features/
│   ├── Library/                 # 已实现：空状态、搜索、排序、网格/列表、文件选择入口
│   ├── Settings/                # 已实现：设置导航与关于/法律基础文案
│   ├── Import/                  # 计划：任务进度、确认与错误恢复
│   ├── Player/                  # 计划：渲染容器及输入覆盖层
│   └── Diagnostics/             # 计划：开发版详细诊断 / Release 普通诊断
└── Resources/                   # 本地化和权利清楚的 App 自有资源
YumeCore/
├── Sources/
│   ├── YumeDomain/              # 已实现首批游戏、引擎与导入状态值类型
│   ├── YumeApplication/         # 已实现 GameLibrary 协议与资料库查询
│   ├── YumeInfrastructure/      # 已实现可替换的内存资料库；持久化等为计划能力
│   └── YumeEngineHost/          # 已实现首版宿主协议骨架
├── Tests/                       # 已实现领域模型与资料库查询单元测试
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

任一阶段可进入 `paused`、`cancelled` 或 `failed`。只有 `validatingCommit` 成功后才能将同卷 staging 原子移动到正式资料库；失败、取消或空间不足时只按任务 manifest 清理本任务未提交文件。App 被终止后依据 checkpoint 恢复，无法证明安全时执行有边界的清理。

只自动展开用户选择的顶层 ZIP/7z，不递归展开其中的通用归档。一个归档发现多个游戏根目录时，每个候选形成独立提交单元。

### 7.2 运行会话

```text
选择游戏 → 校验 manifest/派生版本 → 创建只读 VFS
→ 装配单游戏存档与控制布局 → adapter.prepare
→ 创建唯一 EnginePlayer → running ↔ paused → stopping → released
```

`PlaySessionCoordinator` 保证同一时间只有一个活跃游戏。停止必须释放渲染、纹理、音频、计时器、WebView/解释器状态和输入监听，再恢复系统音频及方向策略。锁屏、后台和音频中断默认暂停；首版不后台持续运行。

### 7.3 存档与离线导入导出

引擎只能读写自己的虚拟存档根。导出由宿主生成仅包含存档与版本元数据的本地包；导入先在临时区验证游戏 ID、引擎/格式版本和路径，再原子替换或合并。游戏本体、密钥、日志和缓存不得混入存档包。

## 8. 本地数据架构

```text
Application Support/Yume/
├── Games/<game-id>/
│   ├── original/                # 不可变导入副本
│   ├── derived/                 # 可重建、删除前需用户确认
│   ├── saves/                   # 用户关键数据，永不自动删除
│   ├── manifest.json            # 检测、输入哈希、配方和版本
│   └── logs/                    # 单游戏滚动日志
├── Staging/<task-id>/           # 未提交任务，受 manifest 约束清理
├── Cache/                       # 可自动清理的普通缓存
├── Diagnostics/                 # App 级诊断索引/导出临时文件
└── Library.sqlite               # 逻辑名称；具体持久化技术待原型确定
```

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
2. 创建 App/Domain/Application/Infrastructure/EngineHost 骨架和本地诊断。
3. 用 MV/MZ 完成第一条纵向切片：ZIP/7z 导入、检测、兼容报告、WKWebView 启动、输入、存档、退出和诊断。
4. 固化安全归档、编码、转换 manifest、恢复和磁盘清理机制。
5. 每次接入一个引擎适配器，并先完成其许可审计、夹具和兼容矩阵。
6. 全引擎达到发布门槛后进入外部 TestFlight 和上架准备。

截至 2026-08-26，上述步骤均未进入代码实现；当前成果是产品约束、决策档案和本文架构基线。

## 16. 架构维护规则

- 新增、删除或重命名顶层模块、关键协议、持久化结构或核心数据流时同步更新本文。
- 架构发生不可逆或跨模块决策时，先在 `Agents.md` 的决策档案中记录，再更新本文的当前结论。
- 本文描述真实结构；工程创建后必须把“预期布局”更新成实际路径，并为关键入口提供相对链接。
- `progress.md` 只记录里程碑状态，`status.md` 只记录当前任务，详细技术结构不重复粘贴到两者。
- 未实现内容必须保留“计划”“目标”或“待验证”标记，禁止让后续 Codex 误认为代码已经存在。
