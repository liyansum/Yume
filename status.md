# Yume 当前任务状态

> 当前任务：根据 build 14 设备日志修复 Kirikiri 字体 abort、Ren'Py EAGL drawable、mkxp Metal 宿主层
> 状态：代码已完成，待 pretest / 提交 / IPA build 15
> 最后更新：2026-08-30

## 根因（build 14，同一份 `error.txt`）

- Kirikiri：`data.xp3` 与 `startup.tjs` 已加载。`system_polyfill/font.ttf` 经 `AddFont` → `TVPEnumFontsProc` → `FT_New_Memory_Face` abort（signal 6）。build 15 若只跳过枚举但仍把游戏 TTF 登记为 `default`，栅格化时仍会 abort。
- Ren'Py：脚本加载成功。`Failed to create OpenGL ES drawable`。LiveContainer 不合成第二 UIWindow；`renderbufferStorage` 发生在 SDL GL view `init` 内。仅给 SDL 窗口设 frame 不够，必须在创建 drawable 前把 CAEAGLLayer 对应 view 挂进 Yume 宿主 view。
- RPG Maker：`metalSublayers=1`，ANGLE 已插入子层。无首帧；宿主 view 当时是普通 `CALayer`。

## 修复

- iOS 上 `TVPEnumFontsProc` / `TVPInternalEnumFonts` 不调用 FreeType，并把请求的字体名别名到已加载的 `default.otf`；`TVPCreateFontStream` 只返回捆绑默认字体。
- `EAGLContext renderbufferStorage:fromDrawable:` 运行时挂钩，在创建 drawable 前把 GL view 插入 `YumeGetHostGameView()`。SDL `empo-ios.patch` 同样在 `init` 里插入宿主 view。
- mkxp 宿主 view `layerClass = CAMetalLayer`，ANGLE 画进 LiveContainer 能合成的层。

## 验证

- 待 `Scripts/verify_pretest.sh`、提交 `main`、GitHub Actions IPA 15
- 不在无新设备日志前宣称运行时成功
- 预期日志：Kirikiri `ios-skip-ft`；Ren'Py `yume.eagl-host-bound` 且无 GLES drawable 失败；mkxp `host.layer class=CAMetalLayer`
