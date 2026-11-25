# SeatSix · 六号座

SeatSix 是一款开源的原生 macOS 播放器，可以连接自己的 Emby 或 Jellyfin 服务器，浏览影片和剧集、搜索片库、收藏影片，并把观看进度同步回服务器。下载版内置 libmpv，在 Mac 上直接解码 MKV、HEVC 等格式。首次使用需要一个可访问的媒体服务器及其账户。

## 下载与安装

1. 打开本仓库的 **Releases**，下载最新版本的 `SeatSix-版本-universal.dmg`。同一个安装包适用于 **macOS 14 或更高版本**的 Apple Silicon 和 Intel Mac。
2. 打开 DMG，把 **SeatSix** 拖到 **Applications（应用程序）**，推出磁盘映像后，从“应用程序”打开 SeatSix。
3. 点击“添加服务器”，选择 Emby 或 Jellyfin，输入服务器地址与账户，登录后勾选要浏览的媒体库。通过局域网连接时，请允许 macOS 的本地网络访问请求。

发布说明列有签名状态。对于标明 **ad-hoc 签名、未经 Apple 公证** 的版本，先将同一 Release 的 DMG 与 `.dmg.sha256` 下载到同一目录，运行以下命令核对文件。若首次打开时 macOS 提示无法验证开发者，确认下载来源后，可在“系统设置 → 隐私与安全性”中对 SeatSix 选择“仍要打开”。[Apple 的应用打开说明](https://support.apple.com/zh-cn/102445)

```sh
cd ~/Downloads
shasum -a 256 -c SeatSix-0.1.0-universal.dmg.sha256
```

## 播放

默认的“自动”模式优先读取服务器原片，由 Mac 解码。即使 NAS 没有转码能力，也可以播放 MKV 中的 HEVC 视频和 AC-3 音频。播放时可以切换可用的音轨和字幕、调整倍速，以及从上次观看的位置继续。外出时如果希望由服务器转码，可在支持转码的 Emby 或 Jellyfin 上选择“兼容”模式，通过 HLS 播放。转码需要当前账户拥有相应权限。

## 从源码构建

准备一台安装了 Xcode 26 或更高版本、Python 3.10 或更高版本的 Mac，并选用 Xcode 的命令行工具。在项目根目录执行以下命令，会下载并校验固定版本的解码库和第三方源码，生成与 Releases 相同配置的 Universal 安装包。

```sh
./scripts/package-release.sh
open build/releases
```

日常开发可用 Homebrew 安装依赖并构建适用于本机的版本。安装 Releases 中的应用无需 Homebrew。

```sh
brew install mpv ffmpeg python
export PATH="$(brew --prefix python)/libexec/bin:$PATH"
./scripts/build-app.sh release --local
open build/SeatSix.app
./scripts/test.sh
```

如需仅使用系统 AVPlayer，可执行 `./scripts/build-app.sh release --public`，生成 `build/public/SeatSix.app`。此配置可直放支持的 H.264/AAC 文件，其他媒体需要服务器提供 HLS 转码流。

报告问题时，请附上 macOS 版本、Mac 芯片、服务器类型，以及可复现步骤。请隐去地址、账号、访问令牌和私人媒体信息。[发布与维护说明](docs/releases.md)

## 许可证

SeatSix 项目代码及项目资源采用 GNU General Public License 第 3 版或任何更新版本（GPL-3.0-or-later）。安装包内附有各解码依赖的许可与署名。每个 Release 同时提供该版本的应用源码和解码依赖源码。[项目许可证](LICENSE) · [第三方媒体库说明](docs/third-party-media.md)
