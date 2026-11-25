#!/bin/bash
# Run from the checked-out, tested commit. Keep incomplete asset uploads in a draft.
set -euo pipefail
tag=${1:?expected tag}
commit=${2:?expected build commit}
assets=${3:?expected asset directory}
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] || exit 2
name="SeatSix-${tag#v}-universal.dmg"
source_name="SeatSix-${tag#v}-decoder-sources.tar.gz"
validator="$(dirname "$0")/publish-release.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check_tag() {
  git fetch -q --no-tags origin "refs/tags/$tag"
  if [[ "$(git rev-parse 'FETCH_HEAD^{commit}')" != "$commit" ]]; then
    echo "Remote tag $tag no longer identifies the tested build." >&2
    exit 1
  fi
}
python3 "$validator" --check "$assets" "$tag"
check_tag

marker="<!-- SeatSix release $commit -->"
# Listing also finds drafts. Authentication or transport failures stop publication.
state=$(gh api --paginate 'repos/{owner}/{repo}/releases?per_page=100' \
  --jq ".[] | select(.tag_name == \"$tag\") | if .draft and ((.body // \"\") | contains(\"$marker\")) then \"resume\" else \"existing\" end")
case "$state" in
  '')
    cat > "$work/notes.md" <<NOTES
适用于 macOS 14 及以上版本，支持 Apple Silicon 和 Intel。下载 DMG，把 SeatSix 拖入“应用程序”，然后添加自己的 Emby 或 Jellyfin 服务器。

DMG 内置 libmpv 和 FFmpeg，可在本机解码 MKV、HEVC 等媒体，无需另外安装播放器或解码器。本工作流生成的安装包采用 ad-hoc 签名，首次打开方式与 SHA-256 校验步骤见仓库 README。

如需查看或重建内置解码组件，请下载同版本的 decoder-sources.tar.gz。

$marker
NOTES
    gh release create "$tag" --verify-tag --draft --target "$commit" --title "SeatSix ${tag#v}" --notes-file "$work/notes.md"
    ;;
  resume) ;;
  *) echo "Release $tag already exists. Only a matching automated draft can be resumed." >&2; exit 1 ;;
esac

gh release upload "$tag" "$assets/$name" "$assets/$name.sha256" \
  "$assets/$source_name" "$assets/$source_name.sha256" --clobber
# Verify the assets GitHub will serve before making the draft public.
mkdir "$work/download"
gh release download "$tag" --dir "$work/download"
python3 "$validator" --check "$work/download" "$tag"
for checksum in "$name.sha256" "$source_name.sha256"; do
  cmp "$assets/$checksum" "$work/download/$checksum"
done
check_tag
gh release edit "$tag" --draft=false
