# 发布 SeatSix

GitHub Release 的源码对应标签提交。DMG 包含内置 libmpv 的 Universal 应用和 Applications 快捷方式。每个版本同时发布解码依赖的对应源码，应用源码可从同一标签获取。

## 本地制作安装包

在装有 Xcode 26 或更新版本及 Python 3.10 或更新版本 的 Mac 上执行以下命令。首次打包需要网络以获取锁定的依赖。脚本校验输入，构建完整应用并验签，然后创建只读映像、解码依赖源码包以及各自的 SHA-256 校验文件。

```sh
./scripts/package-release.sh v0.1.0
(
  cd build/releases/v0.1.0
  shasum -a 256 -c SeatSix-0.1.0-universal.dmg.sha256 SeatSix-0.1.0-decoder-sources.tar.gz.sha256
)
```

从 DMG 把 SeatSix 拖到“应用程序”，推出映像，然后打开安装的副本。运行 `python3 scripts/test-release-decoder.py /Applications/SeatSix.app` 可用合成的 10 位 HEVC/AC-3 样片验证本机架构的包内解码、音频推进和定位。发布前也应在原生窗口验证首次启动、添加服务器和播放。版本号取自 `scripts/Info.plist` 中的 `CFBundleShortVersionString`。发布新版本时同时递增 `CFBundleVersion`。

## 发布到 GitHub

在公开源码仓库为通过测试的提交推送匹配的 `vX.Y.Z` 标签。GitHub Actions 会在 macOS 上从标签构建；在 Apple Silicon 和 Intel 运行器上分别挂载同一份 DMG，复制应用后推出映像，启动安装的应用验证主窗口，并解码样片。两个架构均通过后，工作流创建草稿，上传安装包、解码源码及两份校验文件，重新下载比对内容，再确认远端标签仍指向实际构建的提交后公开。上传中断时可重新运行工作流，继续同一提交创建的草稿。默认发布流程使用 ad-hoc 签名，下载页面会说明首次打开方式。

从含本机开发资料的旧仓库迁移时，在旧仓库运行 `python3 scripts/export-public-source.py /path/to/new/SeatSix`。目标目录必须尚未存在。该命令按清单从已提交的快照导出公开文件，并保留可执行权限。在新目录建立独立 Git 历史，以此为公开仓库的起点。常规贡献直接在公开仓库内提交。

## Developer ID 签名和 Apple 公证

持有 Developer ID Application 证书的维护者可从同一标签在 Mac 上制作公证版。私钥保存在签名机器的钥匙串内。先通过 `xcrun notarytool store-credentials` 在钥匙串创建公证配置，再执行以下命令。

```sh
export SEATSIX_DEVELOPER_ID='证书的 40 位 SHA-1 指纹'
export SEATSIX_NOTARY_PROFILE='钥匙串中的公证配置名称'
./scripts/package-release.sh v0.1.0
```

脚本将 app 与 DMG 提交 Apple 公证，附加并验证公证票据后计算校验值。发布公证版时，在推送对应标签前关闭默认的 GitHub Release 工作流；将上述四份产物上传到该标签的 Release，并在发布说明中注明公证状态。更新和卸载均可通过 Finder 完成。替换应用会沿用现有 SeatSix 连接与本机数据。
