# Yume 当前任务状态

> 当前任务：修复 IPA 15 编译失败后重新出包
> 状态：已把 EAGL drawable 参数改为 `id`，待提交并重跑 Actions
> 最后更新：2026-08-30

## 根因（build 14 日志，同一份 error.txt）

- Kirikiri：`startup.tjs` 对 `system_polyfill/font.ttf` 调 `AddFont`，FreeType `FT_New_Memory_Face` abort（signal 6）。
- Ren'Py：脚本加载后 `Failed to create OpenGL ES drawable`（LiveContainer 不合成第二 UIWindow）。
- RPG Maker：ANGLE Metal 子层已出现，无首帧。

## 已推送修复（IPA build 15）

- Kirikiri：游戏 TTF 只别名到捆绑 `default.otf`，`TVPCreateFontStream` 不再把游戏字体交给 FreeType。
- Ren'Py：挂钩 `renderbufferStorage:fromDrawable:`，在创建 drawable 前把 GL view 插入宿主；SDL patch 同样插入 `YumeGetHostGameView()`。
- mkxp：宿主 view `layerClass = CAMetalLayer`。
- Pretest：129 tests passed。

## 下一步

- 等 IPA 15 产物，装到 LiveContainer 后再导出日志。
- 核对：Kirikiri `ios-skip-ft`；Ren'Py `yume.eagl-host-bound` 且无 GLES drawable 失败；mkxp `host.layer class=CAMetalLayer`。
- 无新设备日志前不宣称运行时成功。
