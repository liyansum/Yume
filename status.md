# Yume 当前任务状态

> 当前任务：IPA build 19 — 三个原生引擎启动、显示、输入和退出路径修复
> 状态：本地预检通过，等待推送并触发 GitHub Actions `Build test IPA`
> 最后更新：2026-08-30

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

## 验收重点

- Kirikiri：画面和文字方向正确，点击可推进；复杂游戏含 `.tpm` 时可导入并显示警告。
- RPG Maker：日志越过 `sharedstate.init.begin`，出现 shader/`cpu-frame.first`，画面可见且退出有效。
- Ren'Py：`renpy-python.log` 出现 `yume.renpy-main.begin`；能进入游戏画面且退出有效。若仍失败，入口面包屑可区分 Python 启动前与游戏脚本阶段。
