# Yume 当前任务状态

> 当前任务：根据 build 15 设备日志修复 Kirikiri FreeType abort、Ren'Py EAGL/软件渲染
> 状态：代码进行中，待 pretest / IPA 16
> 最后更新：2026-08-30

## build 15 日志（Generated 2026-08-30T12:11:03Z）

- Kirikiri：启动脚本完成，`native.first-frame` 已发出；随后 `TVPCreateFontStream` 打开捆绑 `default.otf` 时 FreeType abort（signal 6）。
- Ren'Py：`yume.eagl-host-bound` 已出现，但 `renderbufferStorage` 仍失败。
- mkxp：宿主已是 `CAMetalLayer`，graphics-init 成功，无首帧。

## 修复（IPA 16）

- Kirikiri：`FT_Open_Face` 用 SIGABRT 保护；失败则用 PingFang/Hiragino CoreText 栅格化。
- Ren'Py：宿主 view 改为 `CAEAGLLayer` 作为 drawable；并设置 `RENPY_RENDERER=sw`。
- mkxp：`framebufferOnly=NO`，便于 ANGLE 呈现。

## 下一步

- pretest、提交、dispatch IPA 16。无新设备日志前不宣称运行时成功。
