# Yume 当前任务状态

> 当前任务：修复 IPA 链接失败、Kirikiri SIGABRT、Ren'Py pyobjus，并加入每游戏 7.x/8.x 选择
> 状态：代码已完成，待编译 IPA（build 11）
> 最后更新：2026-08-30

## 根因

- IPA：`mkxp_setHostNativeLayer` 写在会进预编译 `libmkxpz-core.a` 的源里，CI 没有重编该库。
- Kirikiri：StartApplication 在后台线程跑，加载 default.otf 后 SIGABRT。
- Ren'Py：chdir 进 Windows 导出目录后 `lib/python2.7/iosupport.py` 用 pyobjus 找 macOS Foundation。
- RPG Maker：构建 7 已正确识别 VX Ace 并启动 RGSS 线程，但 SDL 全屏窗口仍盖住 LiveContainer。

## 修复

- CI 在 staging 后从源码重编 `libmkxpz-core.a`。
- Kirikiri 创建/打开/取帧回到主线程。
- Ren'Py chdir 到捆绑 base；存档路径优先 `RENPY_PATH_TO_SAVES`；详情页可手动选 7.x/8.x。
