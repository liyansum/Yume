# Yume 当前任务状态

> 当前任务：build 18 — Kirikiri 翻转/点击、Maker 露出 Metal 以便 shader、Ren'Py 不再强制 GLES
> 状态：代码进行中
> 最后更新：2026-08-30

## build 17 日志

- Kirikiri：已出画，画面上下颠倒；点击未进下一话。CPU 帧 origin 在底部。
- RPG Maker：`sharedstate.init.begin` + graphics-init 后卡住，无 `sharedstate.init.end`（隐藏 Metal 层上编 shader）。
- Ren'Py：`RENPY_RENDERER=sw` 仍被 GLES hint 带进 EAGL，`eagl-storage ok=0` 后 signal 11。

## IPA 18

- Kirikiri：显示前垂直翻转像素，触摸 Y 同步翻转。
- mkxp：ANGLE Metal 层保持可见（在 UIImageView 下面），shader.init 打日志。
- Ren'Py：software hint，不再设 GLES / 不再挂钩 EAGL。
