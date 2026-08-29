# Yume 当前任务状态

> 当前任务：根据 build 13 真机日志修复 Kirikiri 游戏字体 abort、Ren'Py EAGL drawable、mkxp 宿主层
> 状态：代码已完成，待编译 IPA（build 14）
> 最后更新：2026-08-30

## 根因（build 13 日志）

- Kirikiri：路径大小写恢复成功，`data.xp3` 已挂上（12 dirs / 63 files），`startup.tjs` 开始执行。随后加载 `system_polyfill/font.ttf` 时仍走 `TVPInternalEnumFonts` 的 SFNT 名表，SIGABRT(6)。
- Ren'Py：脚本已加载（`Loading script took 1.40s`）。`initWithWindowScene:` 未设 frame，EAGL `renderbufferStorage` 失败：`Failed to create OpenGL ES drawable`。
- RPG Maker：`demote sdl hidden=1 appWindows=1`，`backingScale=3.00`。graphics-init 后无首帧日志，进程无信号退出。

## 修复

- iOS 上 `TVPInternalEnumFonts` 只注册 FreeType `family_name`，不再解析 SFNT。
- 路径恢复失败时从 `/var/mobile` 或 `/private` 往下 readdir；HOME 增加 `/private` 变体。
- SDL 在 `initWithWindowScene:` 后设置 `uiscreen.bounds`；Ren'Py 启动前强制 GLES2 属性。
- mkxp 宿主层记录 Metal 子层数量。

## 验证

- 已通过：`./Scripts/verify_pretest.sh`（129 tests）
- 待：GitHub Actions `Build test IPA`（build 14）
