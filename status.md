# Yume 当前任务状态

> 当前任务：建立多引擎宿主层（引擎目录 GameEngineCatalog + 独占会话 PlaySessionCoordinator），移除引擎硬编码白名单
> 状态：已完成（静态验证通过，待 Swift 6/macOS 编译复核）
> 最后更新：2026-08-26

## 目标

- 让“哪个引擎能被真正运行”成为单一来源策略，而不是散落在存储层和 UI 的硬编码。
- 为逐个接入引擎适配器提供统一挂点：检测器声明 `runtimeAvailable`，目录派生宿主形态。
- 保证同一时间只有一个活跃游戏会话，且检测只读引擎在触碰内容前即被拒绝。

## 已完成

- `GameDetector` 协议新增 `runtimeAvailable` 要求；`SignatureGameDetector` 原有同名存储属性直接满足，测试替身同步补齐。
- 新增 `EngineHostingKind`（detectionOnly / restrictedWeb / dedicatedRuntime）、`GameEngineCatalogEntry`、`GameEngineCatalog`：从检测器列表派生每个引擎的宿主形态；`restrictedWebEngines` 静态集合是全仓库唯一携带 Web 引擎 ID 策略的位置；未知引擎默认 detectionOnly（失败关闭）。
- 新增 actor `PlaySessionCoordinator`：启动前依次校验游戏存在 → 兼容状态可运行 → 目录判定可宿主 → 内容定位成功后才占用独占槽位；同游戏重复启动幂等；`stop()` 返回会话归属游戏 ID 并释放槽位。
- `LocalGameStorage.contentLocation` 移除内置的 MV/MZ/TyranoScript 白名单，只负责内容根定位、www 包装下钻与入口文件存在性校验；运行时可用性判断完全上移到 Application 层。
- `AppModel` 组合根接入目录与会话协调器：启动走 `playSessions.start(gameID:)`，退出走 `stop()` 后再记录最近游玩；`engineCatalog` 暴露给设置页。
- 设置页“兼容性”改为由 `GameEngineCatalog.entries` 驱动（名称、兼容带、宿主状态图标），删除手工维护的八元组数组；新增 dedicatedRuntime 状态展示与四语言文案。
- 测试：新增目录派生（Web/独立运行时/仅识别三类 + 未知引擎默认值）、独占会话（双游戏互斥、同游戏幂等重启、stop 释放）、仅识别引擎拒绝且不触碰内容、缺失/不可运行游戏拒绝等用例；测试总数增至 48 个方法。

## 当前变更文件

- `YumeCore/Sources/YumeApplication/GameDetection.swift`
- `YumeCore/Sources/YumeApplication/GameEngineCatalog.swift`（新增）
- `YumeCore/Sources/YumeApplication/PlaySessionCoordinator.swift`（新增）
- `YumeCore/Sources/YumeInfrastructure/LocalGameStorage.swift`
- `YumeApp/App/AppModel.swift`
- `YumeApp/Features/Settings/SettingsView.swift`
- `YumeApp/Resources/{en,ja,zh-Hans,zh-Hant}.lproj/Localizable.strings`
- `YumeCore/Tests/YumeApplicationTests/GameDetectionTests.swift`
- `YumeCore/Tests/YumeApplicationTests/PlaySessionCoordinatorTests.swift`（新增）
- `ARCHITECTURE.md`、`progress.md`、`status.md`

## 关键判断

- 宿主策略集中在 `GameEngineCatalog`：存储层不再知道“哪些引擎能跑”，未来接入 ONS/Kirikiri/Ren'Py 适配器时只需注册检测器并更新目录，UI 与存储零改动。
- 会话协调器把“游戏存在/可运行/可宿主”三道校验全部前置到内容访问之前；仅识别引擎连文件系统都不会触碰。
- `contentLocation` 保持纯定位语义（含 index.html 入口校验），为未来非 Web 引擎返回不同入口类型留出空间；当前非 Web 游戏会在协调器层先被拦截。
- 排期调整记录：负责人指示夹具制作放在 App 全部内容之后、规则 4.7 与品牌/法律复核放在所有引擎实现之后；已写入 `progress.md`，`Agents.md` 未改动，发布类门禁仍以 `Agents.md` 为准。

## 验证结果

- `git diff --check` 通过；全部 Swift 文件花括号/圆括号结构检查通过（含三引号字符串）。
- 四语言 Localizable.strings 键集完全一致（各 143 键），新增 `compatibility.runtime.dedicated` 四语齐备。
- async 调用未放入 XCTest 同步 autoclosure；@Sendable 闭包不捕获可变局部变量（计数器改用 actor）。
- 敏感凭据模式扫描未发现命中。
- 当前 Linux 环境没有 Swift/Xcode 工具链，未实际运行 `swift test` 或 iOS 构建；上述结果不能视为编译通过。

## 阻塞

- 编译与运行验证仍需要 Swift 6/macOS Xcode 环境；平台无关的多引擎基础设施开发不受阻。

## 唯一下一步

继续多引擎核心：定义首个非 Web 引擎适配器骨架（建议 ONScripter 或 Kirikiri 的探测/准备契约），或先在 Swift 6/macOS 环境完成编译与测试复核后继续。
