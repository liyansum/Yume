# Yume 当前任务状态

> 当前任务：全量检查并修复导入识别、RAR、RTP、运行时黑屏/闪退、诊断与 UI
> 状态：已完成代码与 pretest；待推送 GitHub 并触发 IPA 编译
> 最后更新：2026-08-29

## 完成

- 拓宽八引擎识别：ONS `00.txt`、Ren'Py `.rpyc`、Kirikiri 任意 XP3；折叠嵌套根；Windows DLL 不再误拒可运行包。
- ZIP 支持 CP932/GBK 等文件名与反斜杠路径；新增未加密 RAR/RAR5 导入（libarchive 只读子集）。
- RTP 改为 ZIP/7z 复制导入，自动识别 XP/VX/VX Ace，无法识别时由用户选择世代。
- 运行时：mkxp 延后设置游戏路径、AetherKiri 引擎队列与崩溃面包屑、Ren'Py `--basedir` 指向捆绑 base；虚拟按键不再挡住画面点击。
- 诊断：运行时日志、导入失败元数据、开发者页显示 metadata；Release 隐藏开发者页。
- 资料库封面读取游戏内图片，去掉无效占位头；四语言键一致。
- `Scripts/verify_pretest.sh`：127 个测试通过。

## 下一步

推送 `main` 并 `workflow_dispatch` 编译 unsigned IPA。
