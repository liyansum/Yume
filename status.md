# Yume 当前任务状态

> 当前任务：实现导入协调器状态机与启动恢复/取消策略
> 状态：已完成（静态验证通过，待 Swift/macOS 编译复核）
> 最后更新：2026-08-26

## 目标

- 为导入阶段建立显式、可测试且支持分支的状态转换规则。
- 建立 actor `ImportCoordinator`，统一开始、推进、暂停、恢复、失败、取消和完成操作。
- 让取消/失败清理可重试且幂等；终端 manifest 残留可在下次启动安全清理。
- 启动恢复时不盲目继续中断中的文件操作，先落到需重新验证的暂停检查点。

## 已完成

- 安全存储根与 staging manifest 已作为提交 `b07640a` 同步到私有 `origin/main`。
- 新增纯 `ImportStateMachine`，显式限制复制/解包、歧义处理、转换与提交分支；非法跳步会返回类型化错误。
- pause、resume、取消、同阶段推进及相同终态请求具备明确定义的幂等行为；失败码、完成游戏 ID 非空及重复 ID 均会验证。
- `committed` 明确表示已越过原子提交点，此后禁止普通取消/失败；中断时可以暂停核对，恢复后只能完成。
- 新增 actor `ImportCoordinator`，统一创建任务、持久化转换、终态清理与已清理任务的重复终止请求。
- 启动恢复将 active 任务写为同阶段 paused；paused 任务保持不变；残留终态任务重试清理；单任务 manifest、checkpoint 或清理问题独立报告。
- staging 任务发现与 manifest 读取解耦，使一个损坏 manifest 不会阻止其他合法任务进入恢复流程；未知顶层条目和符号链接仍失败关闭。
- `StagingManifest` 解码时重新验证失败/完成终态载荷，并去重归属路径，拒绝语义损坏的持久化状态。
- 修正 `ImportStage`、`CompatibilityStatus`、`LibrarySort` 和根导航 `Section` 缺少显式 `Hashable` 声明的编译协议缺口。
- 新增状态机与协调器测试，覆盖两条合法主分支、非法跳步、幂等操作、缺失任务、终态清理及混合恢复故障。
- 更新 `ARCHITECTURE.md` 与 `progress.md` 的真实实现状态。

## 当前变更文件

- `YumeCore/Sources/YumeDomain/ImportStateMachine.swift`
- `YumeCore/Sources/YumeDomain/ImportModels.swift`
- `YumeCore/Sources/YumeDomain/GameModels.swift`
- `YumeCore/Sources/YumeDomain/StorageModels.swift`
- `YumeCore/Sources/YumeApplication/ImportCoordinator.swift`
- `YumeCore/Sources/YumeApplication/ImportStagingStorage.swift`
- `YumeCore/Sources/YumeApplication/GameLibrary.swift`
- `YumeCore/Sources/YumeInfrastructure/LocalGameStorage.swift`
- `YumeCore/Tests/YumeDomainTests/ImportStateMachineTests.swift`
- `YumeCore/Tests/YumeDomainTests/StorageModelsTests.swift`
- `YumeCore/Tests/YumeApplicationTests/ImportCoordinatorTests.swift`
- `YumeCore/Tests/YumeInfrastructureTests/LocalGameStorageTests.swift`
- `YumeApp/App/RootView.swift`
- `ARCHITECTURE.md`
- `progress.md`
- `status.md`

## 关键判断

- 恢复中的 active 任务先持久化为同阶段 paused，调用方重新验证输入、空间、配方版本后才可 resume。
- 取消、失败和完成先写终态，再清理对应 staging；清理失败则保留终态 manifest，供下次启动重试。
- 已清理任务再次收到终止操作时返回 `alreadyAbsent`，不扩大目标或重建任务。
- `committed` 后不再允许取消/普通失败，防止未来把已进入 `Games/` 的内容当作未提交临时数据处理。
- 恢复报告只暴露稳定问题类别与任务 ID，不把底层路径或错误正文跨层泄漏。

## 验证结果

- `git diff --check` 通过；全部 Swift 文件花括号与圆括号结构检查通过。
- `ImportStagingStorage` 的生产实现与测试替身均已补齐任务存在性查询，协议一致性静态检查通过。
- 当前测试集共 27 个测试方法，本切片新增 11 个状态机、协调器和 manifest 语义验证用例。
- async 调用未放入 XCTest 同步 autoclosure 的静态扫描通过。
- 敏感凭据模式扫描未发现命中。
- 当前 Linux 环境没有 Swift/Xcode 工具链，因此未实际运行 `swift test` 或 iOS 构建；上述结果不能视为编译通过。

## 阻塞

- 编译与运行验证仍需要 Swift 6/macOS Xcode 环境。继续增加平台无关模型不受阻，但在把协调器接入 SwiftUI 前必须先完成编译与模拟器复核。

## 唯一下一步

在 Swift 6/macOS 环境运行核心测试与 iPhone/iPad 构建；修正编译问题后实现检测证据模型、确定性检测注册表与冲突结果，再将只读导入任务状态接入 App UI。
