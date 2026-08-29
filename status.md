# Yume 当前任务状态

> 当前任务：根据 build 11 真机日志修复 Kirikiri 字体 abort、Ren'Py `main.py.py`、mkxp 窗口尺寸
> 状态：代码已完成，待编译 IPA（build 12）
> 最后更新：2026-08-30

## 根因（build 11 日志）

- Kirikiri：`loaded font: .../default.otf` 之后、`enumerated font faces=` 之前 SIGABRT(6)。崩溃在 `TVPInternalEnumFonts` 的 FreeType SFNT 名表解析，不是主线程问题。
- Ren'Py：官方 `launcher_main` 对 argv[0] 做 `basename + ".py"`，再在 `dirname(argv[0])/base/` 下找脚本。传入 `.../base/main.py` 变成 `main.py.py`，两代都 `engine.main-returned result=2`。7.x 再启动 SIGSEGV(11)。
- RPG Maker：`mkxp_setHostViewSize` 传了像素，`SDL_SetWindowSize` 在 iOS 只污染逻辑尺寸缓存。`graphics-init winSize=1179x2556 backingScale=1.00`。

## 修复

- Kirikiri iOS：加载 `default.otf` 后直接注册 `default` 字体面，跳过 SFNT 枚举和额外字体目录。
- Ren'Py：argv[0] 改为 `Runtimes/RenPy{Legacy|Modern}/main`（无 `.py`），chdir 到含 `base/` 的世代根目录，并设置 `PYTHONHOME` 为 `base/`。
- mkxp：宿主尺寸改为 point；iOS 不再 `SDL_SetWindowSize`；graphics-init 优先用宿主 point 尺寸计算 backingScale。

## 验证

- 已通过：`./Scripts/verify_pretest.sh`（129 tests）
- 待：GitHub Actions `Build test IPA`（build 12）
- 待：真机日志确认 `enumerated font faces=1 (ios-safe)`、`engine.argv0=.../RenPy*/main` 且不再出现 `main.py.py`、`host.view-size points=` 且 `backingScale` 不为 1.00

## 下一步

1. 跑 pretest
2. 提交并推送 `main`
3. `gh workflow run "Build test IPA"`
