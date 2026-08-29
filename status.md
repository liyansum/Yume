# Yume 当前任务状态

> 当前任务：修复 XP3 线程闪退、VX Ace 错用 Ruby 1.8、RTP 多世代 ZIP 导入
> 状态：代码已完成，待推送并编译 IPA
> 最后更新：2026-08-29

## 根因

- Kirikiri：`dispatch_sync` 在主线程创建引擎，DisplayLink 却在后台队列取帧，触发 “engine handle must be used on the thread where engine_create was called”。
- VX Ace：只扫顶层文件，把带包装目录的 `Game.rgss3a` 当成 RGSS1/2；RTP 未导入时 `rtp.mount-count=0` 后 abort。
- RTP：只精确匹配文件夹名 XP/VX/VXAce，整包多个 `app` 被当成歧义；已导入其中一代会让整包失败。

## 修复

- Kirikiri 所有 engine_* 回到创建线程（主线程）；存档写到游戏 saves 目录。
- Ruby 代际根据 Game.ini / 递归 rgss3a、rvdata2 判断。
- RTP 按父目录名识别多个世代，优先 `app`，跳过 `sys`，已导入的世代跳过而不是整包失败。
