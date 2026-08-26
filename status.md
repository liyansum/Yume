# Yume 当前任务状态

> 当前任务：多引擎集成层补全（ADR-0053 落地第一批）——RTP 本地映射、RGSSAD 读取、CWS 全量解析、启动计划适配器、上游选型 ADR 与 GPL 合规基建
> 状态：代码与决策层完成（静态验证通过）；"真机可用"仍被 macOS/Xcode 编译验证阻塞
> 最后更新：2026-08-26

## 目标

- 把 ADR-0053 从决策推进为可编译的集成层：每个引擎族都有确定的启动路径声明。
- 交付 RGSS 游戏的两个关键前置：RGSSAD v1 归档索引 + 用户自带 RTP 本地导入/映射/管理。

## 已完成

- **调研锁定**（2026-08-26 核对）：mkxp-z（GPL-2.0+，dev 分支持续构建，须关闭 enable-https）、ONScripter 20230825（GPL-2.0-only）、krkrsdl2（MIT 核心+非 GPL 第三方组件待审）、Ruffle v0.4.1（Apache/MIT 双许可）。
- `CYumeZlib` 新增 `yume_zlib_inflate_mem`：内存到内存 zlib 解压（含 adler 尾校验），供 SWF CWS 压缩体使用。
- `SWFFileParser` 升级：CWS 不再只读头部，压缩体全量解压后走统一 RECT/帧/tag 解析；容量上限 64 MiB 展开体/128 MiB 输入。
- `RGSSArchive`：RGSSAD v1 索引（滚动密钥解密 TOC、路径归一、大小写查重、越界校验）+ 未加密条目流式提取；v3 仅识别并明确报 `versionThreeUnsupported`（其数据带混淆表，留给 mkxp-z 运行时处理）。
- **用户 RTP 体系**：`RTPPackage/RTPIndex` 值类型 + `GameRuntimePackageStore` 协议 + `LocalGameStorage` 完整实现（`RTP/<engine>/<name>/` 目录、manifest.json 索引、名称白名单、去重、树校验复制、删除前恢复写权限、按游戏解析挂载根）。App 侧新增 RTPSettingsView（导入选引擎→文件夹选择器→列表/滑动删除），四语言 +12 键（各 182 键配对）。
- **启动计划适配器层**：`LaunchKind/.web/.hostedRuntime/.notPlanned` + 八个引擎的适配器注册表（web 三家 / rgss→mkxp-z 需 RTP / ons/kirikiri/flash→各自运行时 / renpy→评估中），未知引擎失败关闭；测试覆盖。
- **合规基建**：LICENSE（GPL-2.0-or-later 声明 + GPLv2 组合说明 + 待补 COPYING.GPLv2 正文标注）；Agents.md 新增 ADR-0054～0057 四份上游选型记录（含来源链接、许可核对日期、关键条件）。
- 测试新增：启动适配器 3 例、RGSSAD 3 例；累计 54 个测试方法。

## 关键判断

- RGSSAD v3 数据段有混淆表且 mkxp-z 运行时会自行挂载归档，Yume 读取器只做导入期诊断，v3 索引不实现——诚实边界优于半成品解密。
- RTP 挂载根按 engineID 匹配游戏引擎；缺失时由运行时/诊断给出错误码，UI 不做静默兜底。
- 启动计划层是未来把 `.hostedRuntime` 接到 C/FFI 桥的单一挂点；当前 PlaySessionCoordinator 行为不变（仅 web 三家可启动）。

## 验证结果

- 全部 Swift 文件括号结构检查通过；四语言 182 键完全一致；`git diff --check` 通过；无凭据命中。
- 未运行 swift test / iOS 构建（本环境无工具链）；所有新格式实现需合法夹具在 macOS 上回归。

## 阻塞

- **唯一硬阻塞**：Swift 6/macOS Xcode 环境。没有它无法：① 编译复核全部代码 ② 验证 mkxp-z/Ruffle/ONScripter/krkrsdl2 的 iOS 静态构建 ③ 用真实游戏文件回归格式读取器。这是"多引擎真机可用"前必须由具备条件的环境完成的一步。

## 唯一下一步

在 macOS/Xcode 环境：① `swift test` 全绿 + iPhone/iPad 构建通过 ② 按 ADR-0054~0057 锁定各上游 commit 并试跑 iOS 静态构建 ③ 用自有夹具回归 XP3/RPA/SWF/RGSSAD/NSA 读取器。完成后即可把 `.hostedRuntime` 计划接到真实运行时桥。
