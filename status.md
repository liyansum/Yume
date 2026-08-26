# Yume 当前任务状态

> 当前任务：落实 ADR-0053（GPL 化 + 上游集成路线）——产出各引擎上游选型 ADR 与 SBOM 骨架
> 状态：决策已落档，选型调研进行中
> 最后更新：2026-08-26

## 目标

- 把负责人 2026-08-26 的路线变更完整落入决策档案与架构文档。
- 为五个改走"上游集成"的引擎产出可执行的选型 ADR 骨架（固定 commit、许可证、iOS 可行性、静态构建、退出方案）。
- 设计"用户自带 RTP 本地导入映射"的数据模型与 UI 入口。

## 已完成

- `Agents.md` 追加 **ADR-0053**：放弃 App Store/TestFlight 分发；自有代码改为 GPL-2.0-or-later 开源；RGSS→mkxp-z、ONS→ONScripter、Kirikiri→krkrsdl2、Flash→Ruffle（非 JIT 模式）、Ren'Py→评估官方运行时栈；RTP 改为"用户本地导入映射"，Yume 仍不分发 RTP；商业模式中止。G1 节加了取代说明。
- `progress.md`：商业边界/引擎范围行更新为 ADR-0053 口径；TestFlight 与 App Store 行改为"已取消"；下一里程碑改为上游选型 ADR + RTP 导入映射 + macOS 编译复核。
- `ARCHITECTURE.md` §9 重写为"上游基座"表，标注每个候选的许可证与静态编入要求；Web 三家路径不变。

## 进行中 / 下一步清单

1. 各引擎选型 ADR（每项含：上游 repo、锁定 commit、许可证原文核对、传递依赖初查、SDL2 等公共依赖版本统一方案、iOS 构建方式、包体预估方法、退出方案）。
2. "用户自带 RTP"设计：容器内 `RTP/<engine-id>/` 目录约定、按 GameManifest 记录映射、导入入口（设置页 + 游戏详情缺素材提示）、mkxp-z 的 RTP 路径参数对接。
3. GPL 合规基建：仓库根 LICENSE 变更为 GPL-2.0-or-later、第三方许可页数据源、源码公开与构建说明页面。
4. 既有代码 Swift 6/macOS 编译复核（仍阻塞中）。

## 关键判断

- ONScripter 是 GPL-2.0-only，因此自有代码必须选 GPL-2.0-or-later（不能是 GPL-3.0-only），组合程序按 GPLv2 条款发布。
- Ruffle 无 JIT 解释模式满足 iOS 禁 JIT 约束；其渲染后端在 iOS 上需评估 WGPU/Metal 静态链接成本。
- mkxp-z 自带 PhysFS/SDL2/MRI Ruby，包体与符号管理是最大工程风险；与 Yume 既有 SafeZIP/staging 层的关系需要划清（游戏内容仍经 Yume 导入管线落盘，mkxp-z 只读挂载）。
- RTP 映射不改变"Yume 不分发 RTP"的边界；缺失 RTP 时诊断必须给出明确错误码而非静默失败。
- 用户此前指示"不修改 Agents.md"，本次为记录负责人书面决策所必需的最小修改（G1 取代说明 + 新增 ADR-0053）；如需回退可还原这两处。

## 验证结果

- 文档变更仅涉及四份 Markdown 与决策记录；无代码改动，无需重新静态验证。

## 阻塞

- 上游集成的真实可行性（尤其 mkxp-z/Ren'Py 在 iOS 的静态构建）必须在 macOS/Xcode 环境验证；本环境无法编译任何上游代码。

## 唯一下一步

产出 RGSS/mkxp-z 的首份完整选型 ADR 作为模板（含 commit 锁定与依赖树初稿），再复制到其余四个引擎。
