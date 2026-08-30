# Yume 当前任务状态

> 当前任务：修 RPG Maker LiveContainer 黑屏（CPU blit）并出 IPA 17
> 状态：代码进行中
> 最后更新：2026-08-30

## build 16 日志

- RPG Maker：graphics-init 成功，无首帧；用户只看到虚拟按键。ANGLE `CAMetalLayer` 不被 LiveContainer 合成。
- Kirikiri：`FT_Open_Face aborted` 后用户切走。
- Ren'Py：`RENPY_RENDERER=sw` 仍走 GLES，`eagl-storage ok=0` 后 signal 11。

## IPA 17 修复

- mkxp：每帧 `glReadPixels` 前缓冲，画到宿主 `UIImageView`。ANGLE 的 Metal 层隐藏，只作 EGL 目标。
- Kirikiri：iOS 上不再调用 `FT_Open_Face`，直接 CoreText。
- Ren'Py：不再把宿主层当成 EAGL drawable（避免 SIGSEGV）。

## 下一步

- pretest、提交、dispatch。无新设备日志前不宣称成功。
