# 逐引擎修复记录与真机验收

更新：2026-09-07。基线 `77a4854` 的 GitHub 构建成功，但没有随本次请求提供能够逐游戏关联的真机日志。本轮结论分为代码可重现故障、宿主契约修复和仍需实机验证，不把“编译通过”作为“可以游玩”。

## 共享故障

1. `NativeRuntimeSession` 在全部属性初始化后抛错，Swift 仍会调用 deinit。原先 throw 分支手动释放 callback sink，deinit 再释放，造成重复释放。故障注入已重现 SIGSEGV；修复覆盖 unavailable、创建失败和进程闸门拒绝三个分支，C 桥也清理部分创建的 provider。
2. 非隔离 async 接口会在通用执行器调用 UIKit provider。创建、控制和停止已明确 MainActor；UIKit 析构回到主线程。测试从 `Task.detached` 调用并在 Apple 平台检查主线程。
3. 原生 stop 的 5 秒等待只约束返回后的 STOPPED 事件，无法约束在 provider.stop 内的同步 join。ONS 已有非阻塞 begin/poll teardown；Kirikiri creator-thread 的同步销毁仍需实机检查，不能用强杀线程作为修复。
4. 首帧假阳性掩盖黑屏。窗口出现、SDL ready、Web 文档完成、引擎渲染、宿主呈现现在分别记录；draw 提交仍不能证明内容非黑或显示正确。
5. 随机 Web origin + nonPersistent WebKit 数据库不能持久化 MZ IndexedDB 存档。改用 localForage 官方 localStorage driver，存入单游戏存档桥；Storage 代理补齐属性读/写/删除，覆盖 Ruffle 的 SharedObject 后端。

## 引擎独立调查

| 引擎 | 已发现的问题与代码处理 | 尚需真机证明的边界 |
| --- | --- | --- |
| RGSS XP / VX / VX Ace | mkxp firstFrame 早于宿主图像赋值；terminated 回调早于 SDL_main 清理。改为宿主呈现和主循环返回后确认；覆盖排队启动被取消的退出路径。 | 三代 Ruby、RTP/字体缺失报告、RGB/方向/缩放、键盘/触摸、存读档、音乐与电影。真正进入 Ruby 后仍有单进程一次运行限制。 |
| Ren’Py 7 / Python 2 | SDL UIWindow 存在不代表 renderer 成功；嵌入后暂停 display link 同时停止日志读取。首个 draw_screen 成功写 marker，附着视图后才报告首帧；继续每次最多 64 KiB 的日志读取。 | 7.x 脚本兼容、renderer/ANGLE、点击/拖动、rollback、persistent 与 save、后台恢复。Python 进入后不可安全重入。 |
| Ren’Py 8 / Python 3 | 与 7 相同的宿主问题，但分别核对 modern bootstrap 和 draw_screen 接口并注入独立 hook。 | 8.x 版本带和现代渲染器、视频、输入/存档；不能用 7 的测试结果代替 8。 |
| ONScripter | open_game 等待解释器启动阻塞 UIKit；启动期间 HostExit(0) 留在 Running；dummy/software SDL hints 污染后续会话；同步 join 使 stop 超时失效。已异步 open、失败状态归档、begin/poll shutdown、恢复 hints、记住启动期间暂停请求。 | 文本编码、脚本/归档方言、首帧、点击/拖动、save/load、BGM/电影、正常退出及 ONS→其他引擎交叉启动。卡住的解释器不能强行释放。 |
| Kirikiri / XP3 | 共用 Aether 触摸路径每次 pressed 都发 DOWN，拖动无 MOVE；帧数据尺寸校验不足。已按 pointer ID 区分 MOVE 并限制尺寸/stride/字节数，保持 TVP creator thread。 | KAG/TJS 初始化、XP3/字体/原生插件缺失、画面方向、拖动、存档、音视频和退出。同步 TVP 初始化/销毁卡住时，独立心跳记录阶段，但不能声称已支持任意插件。 |
| RPG Maker MV | 虚拟键同一次 JS 执行立即 down/up，Input.update 看不到按下；大小写折叠的 HTTP 缓存可能读错实际区分大小写的文件。已持有/释放键、暂停释放、精确路径缓存优先。 | frame 轮询输入、斜向组合键、素材大小写、WebGL/音频、存档重启、纯 JS 插件；非浏览器 NW.js 模块需要明确报错。 |
| RPG Maker MZ | 继承 MV 输入/资源问题；localForage 默认 IndexedDB 未接入存档桥。已强制官方 localStorage driver，保持序列化与 Promise/createInstance 语义。 | 持久存档、自动存档、不同 Web origin 重启、PIXI/插件/加密资源和低存储处理。 |
| TyranoScript | 共用 Web 输入、资源错误与 WebGL 诊断不足。沿用原浏览器导出根目录，补输入/异常/资源/场景日志，不错误下沉任意 www。 | v4/v5 文本/按钮、DOM 图层、视频/音频、存档、浏览器插件；DOM 小说可能没有 canvas，因此不能只用 canvas 首帧超时判为失败。 |
| Flash / Ruffle | 未区分 movie.load 成功与画面；相对资源 base/focus 不明确；Storage 缺属性接口。已补 runtime-ready/failed、基于 SWF 的 base、焦点和 SharedObject 桥；networking 用 internal 保留本地资源及存档，由 WK blocker 限制 origin。 | AVM1/AVM2、外部本地 SWF/图像/音频、SharedObject 重启、触摸/虚拟键、WASM/WebGL；首 draw 可能位于 shadow DOM，需实机核实。 |
| Artemis / art3m1s | AVAudioEngine 连接 Int16 交错数据存在格式异常风险；Sound_DecodeAll 无界；帧尺寸改变与首次图像失败缺诊断。改为有界分块解码后 Float32 分平面、帧尺寸调整和统计、后台清除触摸。 | PFS/ASB 版本、字体/画面、音视频回调、存档/触摸、长 BGM 峰值内存。64 MiB 解码上限是保护，不是流式播放实现；超限音频会失败并记日志。 |

## 新诊断链路

`launch.prepared → native.create-requested → view-attached → start-requested → started → first-frame → stop-requested → stopped → released`；Web 另记录 bridge-ready、导航、DOM load、资源、scene、draw 和 runtime-ready/failed。

每次启动先生成 `Games/<id>/logs/session-<UUID>.json`，包含设备/系统/App build/source revision、运行时版本、路径、最近 80 个重要阶段、时间与最后错误。独立心跳记录主线程长期无响应。下次启动恢复未结束会话，原因记为未知中断；强退、系统内存终止、原生崩溃需要结合系统 crash/jetsam 与引擎日志判断。

“诊断导出”和“日志导出”均汇总结构化诊断、App 日志及全部游戏运行日志。新文件优先，单文件尾部 8 MiB、总内容 64 MiB，标题保留游戏归属和截断位置。JSONL 单行损坏不再吞掉全部历史。日志可能包含游戏自身输出；排查时按 sessionID、sourceRevision 和 lastError 关联，不能只比较不同构建的截图。

## 验证与推进顺序

自动化入口：`Scripts/verify_pretest.sh`。包括 Swift 生命周期/异常创建/停止超时与导出/日记/损坏诊断回归，真实 C++ dispatcher 的阻塞 destructor 故障注入，实际 Web 脚本输入/Storage/错误/限流检查，Ren’Py 7/8 hook 行为检查，以及原生缓存内容失效检查。这些测试不加载真实游戏解释器。

macOS workflow 按引擎指纹复用库，Aether ABI 改动必须重编；保存 xcresult/build.log 并将 commit/build 写入 App。文件时间不参与原生有效性判断。最终 IPA 的设备安装与签名由测试方完成。

每个引擎分别完成以下步骤，并保留同一构建对应的诊断导出：

1. 冷启动最小样本，确认入口/首帧，记录耗时、尺寸及是否有声音。
2. 点击/按住方向键 2 秒/拖动，验证 release 后停止动作；横竖屏及 iPad 尺寸变化。
3. 存档后退出、重新启动、读取；MZ/Flash 特别检查随机 origin 重启后的持久性。
4. 持有输入时切后台 10 秒再恢复，检查粘键、声音、画面与首帧误超时。
5. 故意缺少字体/素材/脚本或加载损坏入口，确认错误码、资源路径和最后阶段可导出。
6. 退出后跨引擎启动；已进入 Ruby/Python 或停止超时的场景确认“需要重启进程”，不能继续污染另一个引擎。

Ref 中 Spark、XP3Player、ONSPlayer/iONSPlayer、RPGPlayer/RPGViewer、YuriGame 用于核对进程布局、入口参数、资源和输入策略。部分参考 App 通过独立 executable/framework 隔离 Python/Ruby/SDL；其反编译实现不是当前单进程 C ABI 的可直接替换件。本轮在 Yume 自有宿主及已锁定上游中修复对应行为，未把参考 App 的二进制、商业素材或解包资源加入项目。

上游接口依据：[Ren’Py 8 draw_screen](https://github.com/renpy/renpy/blob/8.5.3.26051504/renpy/display/core.py)、[Ren’Py 7 draw_screen](https://github.com/renpy/renpy/blob/7.8.7.25031702/renpy/display/core.py)、[锁定 Ruffle Storage 后端](https://github.com/ruffle-rs/ruffle/blob/a4f5b5256e245693bc9077ef6c6b6abc95490e7f/web/src/storage.rs)、[Ruffle networking 配置](https://github.com/ruffle-rs/ruffle/blob/a4f5b5256e245693bc9077ef6c6b6abc95490e7f/web/packages/core/src/public/config/load-options.ts)。构建版本与其余上游位置以依赖锁为准。
