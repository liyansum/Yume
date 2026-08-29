# Yume 当前任务状态

> 当前任务：根据 build 12 真机日志修复 Kirikiri 路径大小写、Ren'Py `--basedir` 导致 Python 静默退出 1
> 状态：代码已完成，待编译 IPA（build 13）
> 最后更新：2026-08-30

## 根因（build 12 日志）

- Kirikiri 字体枚举已通过（`enumerated font faces=1 (ios-safe)`）。随后 `NormalizePathName` 把路径改成全小写，`opendir` 在 LiveContainer 上 ENOENT，XP3 未挂载，`startup.tjs` 找不到后主线程对话框回退到取消并终止。
- Ren'Py argv0 已正确（`.../RenPyModern/main`），不再出现 `main.py.py`。官方 `launcher_main` 用隔离 Python 预解析 argv，`--basedir` 被当成未知解释器选项，`result=1` 且无 traceback。`renpy-python.log` 里的 ANGLE/Game.ini 是 stdout 未恢复后被 mkxp 写入的残留。
- RPG Maker `backingScale=3.00`、`hostView=393x852` 已正确。进程在 graphics-init 后无信号退出；宿主 view 不再用 CAMetalLayer 当根层，改回让 ANGLE 插入 Metal 子层。

## 修复

- iOS `GetLocallyAccessibleName` 用 HOME / 工程原路径前缀 + readdir 恢复大小写；AutoMount 失败时回退 `TVPNativeProjectDir`。
- Ren'Py 改为位置参数 basedir，不再传 `--basedir`；python 日志写启动面包屑。
- mkxp 宿主层改回普通 CALayer；demote 后记录 UIWindow 数量。

## 验证

- 已通过：`./Scripts/verify_pretest.sh`（129 tests）
- 待：GitHub Actions `Build test IPA`（build 13）
- 待真机：Kirikiri `iOS path case restore` 且挂上 `.xp3`；Ren'Py `yume.python-redirect-ready` 且 `result=0`；mkxp `sdl-window demote` 后有画面
