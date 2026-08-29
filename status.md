# Yume 当前任务状态

> 当前任务：修复 Ren'Py / Kirikiri 闪退、RPG Maker 黑屏，并按 XP/VX/VX Ace 三代选择运行时
> 状态：代码已完成，待验证并编译 IPA
> 最后更新：2026-08-29

## 根因

- Kirikiri：`engine_open_game_async` 在内部线程跑 TVP，DisplayLink 却在创建线程取帧；LiveContainer 下 `Application Support` 路径再经 `file://./` 目录遍历会损坏。
- RPG Maker：SDL 窗口被 `hidden=YES` 后 ANGLE/Metal 无法呈现；LiveContainer 里嵌套 `dispatch_async` 可能永远不执行 `mkxp_setGamePath`。XP/VX/VX Ace 只分了 Ruby 1.8/1.9，未把 `rgssVersion` 写入 mkxp 配置，VX 可能被当成 XP。
- Ren'Py：同样藏起 SDL 窗口；argv[0] 指向不存在的 `yume-renpy`。

## 修复

- Kirikiri：专用引擎线程上同步 `engine_open_game`；iOS 存储名走直接 POSIX 路径。
- RPG Maker：不隐藏 SDL 窗口、交还 key window；启动前设置 game path；按 Game.ini / Scripts 扩展名选择 RGSS1/2/3 与对应 Ruby 和 RTP。
- Ren'Py：同样的窗口策略；argv[0] 指向真实 `main.py`；Python 输出与崩溃面包屑写入日志。
- MV/MZ/Flash/Tyrano：WKWebView 允许内联媒体播放。
