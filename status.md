# Yume 当前任务状态

> 当前任务：实现安全存储根与 staging manifest 持久化
> 状态：已完成（静态验证通过，待 Swift/macOS 编译复核）
> 最后更新：2026-08-26

## 目标

- 在 `YumeCore` 建立固定且可审计的 App 私有存储布局。
- 为每个导入任务创建独立 staging 工作区和版本化 manifest。
- 提供经过相对路径验证的文件归属登记、状态恢复发现与幂等清理边界。
- 添加路径穿越、manifest 往返、任务隔离和清理不越界测试。

## 已完成

- 首个 App 宿主骨架已作为提交 `59a57b8` 同步到私有 `origin/main`。
- 新增 `StorageRelativePath`，拒绝绝对路径、Windows 盘符、`.`/`..`、空组件、反斜线与空字节，并在 Codable 解码时重新验证。
- 新增版本化 `StagingManifest`，记录任务 ID、导入状态、创建/更新时间及去重后的归属路径。
- 新增 `ImportStagingStorage` 协议和强类型 `StagingWorkspace`，Application 层不获得任意删除 API。
- 新增 actor `LocalGameStorage`，创建固定 `Games/Staging/Cache/Diagnostics` 布局；每个任务使用 `Staging/<task-id>/manifest.json + content/`。
- 实现 manifest 原子写入、任务发现和稳定排序、任务/版本匹配、符号链接拒绝、未知 staging 条目显式报错以及按任务 ID 的幂等清理。
- staging、缓存和诊断选择性排除备份；`Games/` 根不整体排除，避免未来连带排除用户存档。iOS 管理目录和 manifest 使用首次解锁后可用的文件保护。
- 清理回归验证目标仅限对应 staging 任务，不触碰其他任务、`Games/` 哨兵或符号链接目标。
- 更新架构与总体进度文档，明确已实现边界和仍待实现的原子提交、索引、容量预算与恢复协调器。

## 当前变更文件

- `YumeCore/Package.swift`
- `YumeCore/Sources/YumeDomain/StorageModels.swift`
- `YumeCore/Sources/YumeApplication/ImportStagingStorage.swift`
- `YumeCore/Sources/YumeInfrastructure/LocalGameStorage.swift`
- `YumeCore/Tests/YumeDomainTests/StorageModelsTests.swift`
- `YumeCore/Tests/YumeInfrastructureTests/LocalGameStorageTests.swift`
- `ARCHITECTURE.md`
- `progress.md`
- `status.md`

## 关键判断

- staging 元数据与待导入内容分目录保存，避免归档内容覆盖 manifest。
- 清理 API 只接受强类型任务 ID，并从固定 `Staging/<task-id>` 推导目标；不接受任意 URL 或路径。
- 发现损坏、缺少 manifest、未知条目或符号链接时失败并保留数据，不静默猜测或扩大清理范围。
- `Games/` 根保持可备份默认值；后续创建 `original/derived` 时单独排除，`saves/` 保留进入用户加密设备备份的可能。

## 验证结果

- `git diff --check` 通过；Swift 文件花括号与圆括号结构检查通过。
- Swift Package 的四个 Source target 与三个 Test target 目录对应检查通过。
- 当前测试集共 16 个测试方法；本切片新增相对路径、manifest、备份属性、任务发现、幂等清理、孤儿目录和符号链接安全用例。
- 敏感凭据模式扫描未发现命中。
- 当前 Linux 环境没有 Swift/Xcode 工具链，因此未实际运行 `swift test` 或 iOS 构建；上述结果不能视为编译通过。

## 阻塞

- 编译与运行验证需要 Swift 6 工具链；App 构建仍需要兼容 object version 77 的 Xcode。环境限制不影响代码边界设计，但继续扩展协调器前应优先复核。

## 唯一下一步

在 macOS/Swift 6 环境运行 `cd YumeCore && swift test` 及 iPhone/iPad 模拟器构建，修正编译问题后实现导入协调器状态机、启动恢复/取消策略和检测注册表。
