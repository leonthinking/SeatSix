# 本机真实服务集成验证

这些脚本只管理 `theater-dev-jellyfin`、`theater-dev-emby` 两个带当前工作区归属标签的测试容器，以及相同标签的 `theater-dev-{jellyfin,emby}-{config,media,cache}` 专属 Docker volumes，不复用、重置或清理其他容器。只开放本机回环地址端口 18096 / 28096。人工样片源文件和随机测试凭据放在仓库忽略的 `.runtime/` 中。测试账户仅属于这两套空白服务，不是用户现有账户。SeatSix 沿用已有容器、卷和归属标签；测试入口同时识别新旧人工片库与片名。主机和专属卷按直放、转码两种用途复用样片。重建容器只补充卷内缺少的样片及对应说明，目标片库同时索引两种用途后才开始播放验证。

为避免 macOS 对 Downloads 目录的枚举限制，样片只从 `.runtime/media/` 复制进专属 volume，容器不挂载任何主机目录；配置也在各自独立 volume 中。首次迁移会删除本脚本创建且归属标签匹配的旧 bind-mount 测试容器，再用同一份测试凭据初始化新容器，不删除主机文件。

依赖：Python 3.9+、OrbStack（含 Docker CLI）、ffmpeg。从仓库根目录运行统一入口：

```sh
python3 -B scripts/integration/run.py
# 已下载镜像时：
python3 -B scripts/integration/run.py --no-pull
```

入口按需启动 OrbStack，准备两套测试服务，执行 `smoke.py`，最后停止本次启动的测试容器。只有 OrbStack 原本处于停止状态且结束时没有其他运行中的容器或 Linux 机器，才停止 OrbStack；本次新开的应用界面也会退出。原本就在运行的 OrbStack、应用界面和测试容器均保留。若无法核实清理状态，会明确报错并保留 OrbStack，避免误关其他工作负载。容器、镜像、volumes、测试凭据均保留供下次复用。

测试失败、准备失败、Ctrl-C 和 SIGTERM 都会进入收尾；SIGKILL、系统断电无法执行收尾。不同工作区的托管入口使用同一用户锁，同时只允许一个测试会话。本入口明确使用 `orbstack` Docker context，不切换用户默认 context，也不操作环境变量所指向的远程 Docker。收尾前若有其他工作负载启动，保留 OrbStack；外部工具不受此锁约束，因此不要在托管会话收尾的同时启动其他容器任务。

需要额外的播放器或接口验证时，把前台测试命令放在 `--` 后；命令退出即表示测试结束，因此不要传入会立即返回的 `open SeatSix.app` 或后台启动命令：

```sh
python3 -B scripts/integration/run.py --no-pull -- .build/debug/SeatSixProbe YOUR_TEST_ARGUMENTS
```

`setup.py` 的旧调用也转入上述完整流程（包括默认 smoke 验证和收尾），不再作为长驻测试服务器的启动入口。不要手动执行 `orbctl start` / `open -a OrbStack` 来绕过生命周期管理。`smoke.py` 是底层验证步骤，不负责启动环境。

普通离线回归保持独立，不需要启动 OrbStack：

```sh
./scripts/test.sh
```

重复运行会复用本项目已有测试容器和测试凭据，不重新设置密码。凭据在 `.runtime/test-credentials.json`，权限 0600，脚本不打印密码或令牌。应用测试必须显式从该文件读取，不能把密码写进代码、提交或截图。

样片均为本地 ffmpeg 生成的 10 分钟测试图、可见运行计时和 440 Hz 音频。MP4 为 H.264/AAC，MKV 为 MPEG-4/AAC。NFO 说明其人工来源，禁用自动在线图片和元数据抓取。

`smoke.py` 验证真实登录、媒体库、影片详情、PlaybackInfo、MP4 文件头、HLS 播放列表与实际 TS 分片，以及 start → progress → stop 后远端记录达到 120 秒并出现在续播列表。结果写入 `.runtime/integration-results.json`。这不等于已验证 AVPlayer 的音画、seek 或原生界面；应用播放需独立测试。

删除本项目容器但保留数据：

```sh
python3 -B scripts/integration/cleanup.py
```

同时删除本项目专属 volumes、生成样片、历史 bind-mount 配置和测试凭据：

```sh
python3 -B scripts/integration/cleanup.py --purge-test-data
```

归属标签不匹配时脚本会拒绝操作。主机生成目录另有 `.runtime/.theater-integration.json` 工作区标记；缺少标记或目标为符号链接时拒绝删除。清理不删除镜像，不重置 Docker，不触及其他容器或私人媒体。

官方镜像来源：[Jellyfin 容器说明](https://jellyfin.org/docs/general/installation/container/)、[Emby Docker 下载](https://emby.media/docker-server.html)。Apple Silicon 使用 `jellyfin/jellyfin` 与 `emby/embyserver_arm64v8`，其他架构 Emby 使用 `emby/embyserver`。Jellyfin 官方不支持 macOS Docker 生产部署，尤其硬件转码和目录扫描存在主机限制；此处只用于本地人工素材的集成测试。

镜像固定到 `common.py` 中已验证的不可变 digest。2026-10-22 已实际通过 Jellyfin 12.2.0、Emby 4.9.3.0 的两种素材 API 链路（包括服务器远端 120 秒续播）；测试结果不代表其他版本、编解码器或硬件转码已覆盖。

## 用户提供的服务器

`SeatSixProbe --server` 用于明确授权后的私有服务器联调。配置和报告必须放在忽略的 `.runtime/` 中，不能提交账户、地址、影片清单或证书。配置包含 `kind`、`address`、`username`、`password`、`compatibilityMode`；只有用户核对并批准了完整指纹后，才增加 `approvedFingerprint`。不提供该字段时仍使用系统证书信任。

```sh
# 无凭据证书检查：取消 TLS 挑战，不发送登录请求
.build/debug/SeatSixProbe --server inspect .runtime/user-server.json .runtime/certificate.json

# 已获授权后的登录与媒体库读取，报告包含私有片库信息，权限为 0600
.build/debug/SeatSixProbe --server inventory .runtime/user-server.json .runtime/catalog.json

# 明确指定一部影片，沿用原有位置短暂播放、回写进度，再用新播放器续播
.build/debug/SeatSixProbe --server play .runtime/user-server.json .runtime/playback.json ITEM_ID

# 本地解码倍速：四档真实音视频时钟、暂停改速、seek保速、停止回写及新播放器续播
.build/debug/SeatSixProbe --server experience .runtime/user-server.json .runtime/experience.json ITEM_ID

# 剧集分季查询及前两集独立播放 / 停止 / 回读 / 续播；参数为真实父剧 ID
.build/debug/SeatSixProbe --server series-play .runtime/user-server.json .runtime/series-play.json SERIES_ID
```

播放验证会改变指定影片的观看进度，只能在用户授权的服务器和影片范围内执行。验证检查真实像素帧、时间推进、停止后的远端位置及全新播放器恢复位置；`play` 模式另外检查第二次停止回写。失败不会输出含令牌的播放地址；原始报告不应直接拷入公开验证记录。

`experience` 沿用该影片现有位置，仅短时播放；分别测量 0.5×、1×、1.5×、2× 下影片及音频时钟相对于实际耗时的推进，并检查真实画面、暂停和同位置跳转后的速度。随后停止回写，创建新引擎读取服务器位置，确认默认恢复为 1×。这不代替原生键盘和全屏界面验收。连接已有 NAS 不启动本机容器或 OrbStack。

该模式开始时要求剩余时长超过 80 秒，并在每档开始前按余下速度重新检查预热与采样预算；不满足时报告失败，不为采样改写到其他播放位置。

`series-play` 先查询季、完整分集与选定季的子集，再选顺序明确的前两集，分别执行本地解码与续播验证，最后回读第一集确认第二集未改变其位置。该模式会短时播放并跳转，不替代原生自然结束事件、自动切集和窗口保持的验收；不会用父剧 ID 播放或上报。原始报告保存在 `.runtime/`，公开记录须按允许字段脱敏。

证书与转发层的自动测试生成一次性本机 TLS 服务和人工 MP4 / HLS，不使用私人 NAS。macOS Security 信任服务和本机监听需要正常运行权限；沙箱拒绝信任服务时不能把错误归因于服务器证书。
