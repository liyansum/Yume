# Yume 当前任务状态

> 当前任务：IPA build 20 — 全部八类引擎的统一详细运行日志
> 状态：已推送；本地 130 项测试通过；GitHub Actions 真机构建、打包和上传通过
> 最后更新：2026-08-31

## 构建产物

- 代码提交：`a71be68`（统一日志）、`93ea2bf`（补齐 mkxp SDL 初始化日志头）
- GitHub Actions：`Build test IPA` run `33345733139`，结论 `success`
- Artifact：`Yume-unsigned-IPA-48`
- IPA：`Yume-0.1.0-20-unsigned.ipa`（build 20）
- SHA-256：`eb8cdc3d6e0953fda6d31c0f76d7cf9cf8a365b7f6c938025e6fb116a8cbabb7`

## build 18 日志结论

- Kirikiri：引擎已持续输出后续彩色帧，问题集中在 CPU 帧方向、触摸坐标/按钮语义和字体加载。
- RPG Maker/mkxp-z：卡在 Graphics 初始化期间，尚未进入 shader/首帧阶段；主线程没有充分处理 ANGLE/UIKit 请求。
- Ren'Py：`launcher_main` 很快返回 1，日志未进入打包的 `base/main.py`，需要校验 Python 启动资源和参数。

## build 19 修复

- Kirikiri：画面扫描行翻转但触摸保持逻辑坐标；触摸改为主按钮；CoreText 从随包字体创建字形；停止事件同步交付，避免销毁后的回调；显式启用 SDL iOS 事件泵。
- Kirikiri 导入：`.tpm` 从阻止导入改为兼容性警告。iOS 仍不会执行原生 Windows 插件，依赖该插件且无脚本回退的游戏可能不兼容。
- mkxp-z：主事件循环处理 CoreFoundation run loop；Metal 层不再被黑色 CPU 视图遮挡；CPU 帧只保留一帧待显示，避免主队列积压；异步首帧回调不再捕获可释放 session；显式启用 SDL iOS 事件泵。
- Ren'Py：启动前校验 `main.py` 与 Python `site` 模块；使用游戏根目录位置参数并启用 safe mode/software renderer；日志/存档写入应用可写目录；加入 Python 入口面包屑；显式启用 SDL iOS 事件泵。
- 构建脚本：缺失 Ren'Py Python 启动模块时立即失败，避免生成必然无法启动的 IPA。

## build 20 日志增强

- 统一时间线：原生运行时新增结构化日志回调 ABI；Kirikiri、ONScripter、RGSS/mkxp-z、Ren'Py 的宿主与引擎日志实时写入当前 App 会话日志，附带引擎、运行时、来源和级别。
- AetherKiri（Kirikiri/ONScripter）：记录目录可读写状态、启动状态、字体配置、表面尺寸、帧描述与采样统计、触摸坐标映射、输入结果和停止统计。
- mkxp-z（RPG Maker XP/VX/VX Ace）：记录 RTP 挂载、SDL/事件循环心跳、窗口与图层、CPU 帧回调/丢帧/显示统计、键盘与指针处理，以及 mkxp 内部调试日志。
- Ren'Py：记录运行时资源预检、Python 环境与入口阶段、SDL 窗口嵌入心跳、输入投递和退出状态，并把 `renpy-python.log` 增量镜像到 App 时间线。
- Web 运行时（RPG Maker MV/MZ、TyranoScript、Flash/Ruffle）：记录本地资源请求、字节量、导航阶段、DOM/Canvas 快照、JS 控制台/异常/Promise 拒绝、页面生命周期与虚拟按键投递结果。
- 退出安全：清理原生日志回调时与后台线程同步，避免游戏关闭后继续写入已释放的 Swift 日志接收器。
- 原始引擎文件仍保留为原生崩溃兜底；常规排查以单一 App 会话日志为主，完整导出仍汇总所有可读取的日志。

## 验收重点

- Kirikiri：画面和文字方向正确，点击可推进；复杂游戏含 `.tpm` 时可导入并显示警告。
- RPG Maker：日志越过 `sharedstate.init.begin`，出现 shader/`cpu-frame.first`，画面可见且退出有效。
- Ren'Py：`renpy-python.log` 出现 `yume.renpy-main.begin`；能进入游戏画面且退出有效。若仍失败，入口面包屑可区分 Python 启动前与游戏脚本阶段。
