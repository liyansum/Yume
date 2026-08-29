# Yume 当前任务状态

> 当前任务：LiveContainer 下 RPG Maker 在 configure 后闪退/黑屏
> 状态：代码已完成，待编译 IPA（build 8）
> 最后更新：2026-08-30

## 根因

构建 6/7 的 App 日志在 `mkxp.stage.configure.begin` 后约 12 秒进程消失。SDL 在主线程 `CreateWindow` 会新建 UIWindow 并抢 key window；LiveContainer 只合成宿主窗口，ANGLE 绑到那个不可见窗口后黑屏或被 watchdog 杀掉。App 日志异步，所以看不到 `native.started`。

## 修复

- ANGLE 画到 Yume 播放器视图的 CALayer，不再依赖 SDL 的 UIWindow。
- SDL 窗口以 HIDDEN 创建，创建后立即降级并交还 key window。
- `SDL_main` 等到宿主视图进入窗口后再启动。
- 崩溃信号写入 `mkxp-crash.log`。
