# 媒体引擎与构建依赖

## GitHub 下载版

下载版使用 IINA 项目发布的 Universal 解码库，包括 mpv 0.41.0 和 FFmpeg 9.0.1。SeatSix 将库安装到 `Contents/Frameworks`，移除外部搜索路径并重新签名。构建脚本验证主程序及解码库在 arm64、x86_64 两个切片上均能在 macOS 14 或更高版本运行，并核对每个非系统依赖均可从应用包内解析。

项目许可位于 `Contents/Resources/LICENSE`，第三方许可和署名位于 `Contents/Resources/ThirdPartyNotices/`。与二进制对应的上游源文件、子模块和补丁可从同一 GitHub Release 的 `SeatSix-版本-decoder-sources.tar.gz` 获取。源码清单中记录固定版本、上游地址和 SHA-256，随附文档说明如何还原构建输入。[解码库源码与构建说明](decoder-sources.md) · [上游二进制发行](https://github.com/iina/deps-buildscripts/releases/tag/iina-1.5.0-release)

## 系统播放版

`./scripts/build-app.sh release --public` 可构建仅使用 AVFoundation 和 AVKit 的 Universal 应用。这个选项供希望依赖 macOS 系统播放器的使用者自行构建。

## libmpv 本地版

`scripts/build-app.sh release --local` 使用 Homebrew 的 `mpv` 及其依赖，在 Mac 上解封装、解码和渲染视频。构建脚本递归读取可执行文件及每个动态库的 Mach-O 加载命令，找出实际使用的依赖，在暂存目录内完成以下步骤。

1. 将第三方动态库复制到 `Contents/Frameworks`，把加载路径重写为包内相对路径，并移除开发机的搜索路径。依赖缺失、同名冲突或解析存在歧义会中止构建。
2. 逐库验签，在独立进程中实际加载 libmpv 并初始化。随后计算所有切片与库的系统版本要求，将最高要求写入应用的 `LSMinimumSystemVersion`。
3. 生成 `Contents/Resources/media-libraries.json`，记录已安装的版本、来源、原文件校验值、许可证元数据和初始化结果。完成签名及校验后才替换本机应用。

例如，Apple Silicon 上的一组 Homebrew mpv 0.41.0 和 FFmpeg 9.0.2 动态库，要求至少 macOS 27。使用其他 Homebrew 版本构建时，请以生成的应用信息为准。

## 再分发 libmpv 版

SeatSix 的项目许可为 GPL-3.0-or-later。mpv 和 FFmpeg 的许可取决于编译选项和依赖。重新分发包含这些库的二进制时，要按实际打入包内的版本准备第三方声明、完整许可、对应源码、补丁和构建材料。构建清单会记录本机安装版本，Homebrew 当前软件目录中的源地址可能已指向新版。[mpv 版权说明](https://github.com/mpv-player/mpv/blob/master/Copyright) · [FFmpeg 许可说明](https://ffmpeg.org/legal.html) · [Homebrew mpv 配方](https://formulae.brew.sh/formula/mpv)
