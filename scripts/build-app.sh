#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration=debug
configuration_set=false
signing_mode=certificate
usage='Usage: scripts/build-app.sh [debug|release] [--local] | release [--public|--full]'
for argument in "$@"; do
  case "$argument" in
    debug|release)
      if [[ "$configuration_set" == true ]]; then
        echo "$usage" >&2
        exit 2
      fi
      configuration="$argument"
      configuration_set=true
      ;;
    --local|--public|--full)
      if [[ "$signing_mode" != certificate ]]; then
        echo "$usage" >&2
        exit 2
      fi
      signing_mode="${argument#--}"
      ;;
    *)
      echo "$usage" >&2
      exit 2
      ;;
  esac
done
if [[ ( "$signing_mode" == public || "$signing_mode" == full ) && "$configuration" != release ]]; then
  echo "$usage" >&2
  exit 2
fi
if [[ "$signing_mode" == local && ( "${SEATSIX_SIGNING_IDENTITY+x}" == x || "${THEATER_SIGNING_IDENTITY+x}" == x ) ]]; then
  echo 'SeatSix signing: unset signing identity overrides when using --local.' >&2
  exit 2
fi
build_app() {
  configuration="$1"
  signing_mode="$2"
  output_dir="$PWD/build"
  distribution=false
  if [[ "$signing_mode" == public || "$signing_mode" == full ]]; then
    distribution=true
    output_dir="${SEATSIX_PUBLIC_OUTPUT_DIR:-$output_dir/$signing_mode}"
  fi
  unset SEATSIX_SYSTEM_PLAYER
  if [[ "$signing_mode" == full ]]; then
    export SEATSIX_DECODER_PREFIX="${SEATSIX_DECODER_PREFIX:?Set SEATSIX_DECODER_PREFIX to the prepared universal decoder SDK}"
    SEATSIX_DECODER_PREFIX="$(cd "$SEATSIX_DECODER_PREFIX" && pwd -P)"
    notices="${SEATSIX_DECODER_NOTICES:-$SEATSIX_DECODER_PREFIX/ThirdPartyNotices}"
    if [[ ! -f "$SEATSIX_DECODER_PREFIX/include/mpv/client.h" || ! -f "$SEATSIX_DECODER_PREFIX/lib/libmpv.dylib" || ! -d "$notices" ]]; then
      echo 'Expected the prepared decoder SDK and its ThirdPartyNotices directory.' >&2
      exit 1
    fi
  else
    unset SEATSIX_DECODER_PREFIX
    if [[ "$signing_mode" == public ]]; then export SEATSIX_SYSTEM_PLAYER=1; fi
  fi
  mkdir -p "$output_dir"
  staging_root="$(mktemp -d "$output_dir/.SeatSix.XXXXXX")"
  staging_app="$staging_root/SeatSix.app"
  app_path="$output_dir/SeatSix.app"
  previous_app="$app_path"
  if [[ "$distribution" == false && ! -e "$app_path" && -d "$output_dir/Theater.app" && ! -L "$output_dir/Theater.app" ]]; then
    previous_app="$output_dir/Theater.app"
  fi
  cleanup() {
    # A missing staged candidate or link means that rename already happened.
    # Undo those moves before restoring the backups of either original entry.
    if [[ -f "$staging_root/publishing" ]]; then
      if [[ "$distribution" == false && ! -L "$staging_root/legacy-link" && -L "$output_dir/Theater.app" ]]; then
        mv "$output_dir/Theater.app" "$staging_root/legacy-link" || return 1
      fi
      if [[ ! -e "$staging_app" && -d "$app_path" ]]; then
        mv "$app_path" "$staging_app" || return 1
      fi
    fi
    for name in SeatSix.app Theater.app; do
      backup="$staging_root/previous-$name"
      target="$output_dir/$name"
      if [[ -d "$backup" && ! -e "$target" && ! -L "$target" ]]; then
        mv "$backup" "$target" || return 1
      fi
    done
    rm -rf "$staging_root"
  }
  trap cleanup EXIT
  mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
  if [[ "$distribution" == true ]]; then
    slices=()
    player=system
    if [[ "$signing_mode" == full ]]; then player=full; fi
    for cpu in arm64 x86_64; do
      args=(--scratch-path "$PWD/.build/$signing_mode" -c release --arch "$cpu")
      swift build --disable-sandbox "${args[@]}" --product SeatSix \
        -Xswiftc -file-prefix-map -Xswiftc "$PWD=." -Xcc "-ffile-prefix-map=$PWD=." -Xlinker -S
      bin_path="$(swift build "${args[@]}" --show-bin-path)"
      slice="$staging_root/SeatSix-$cpu"
      cp "$bin_path/SeatSix" "$slice"
      python3 scripts/bundle-media-libraries.py "--prepare-$player-slice" "$slice"
      slices+=("$slice")
    done
    lipo -create "${slices[@]}" -output "$staging_app/Contents/MacOS/SeatSix"
    cp LICENSE "$staging_app/Contents/Resources/LICENSE"
    if [[ "$signing_mode" == full ]]; then
      python3 scripts/bundle-media-libraries.py --install-full-sdk "$SEATSIX_DECODER_PREFIX" "$staging_app"
      cp -R "$notices" "$staging_app/Contents/Resources/ThirdPartyNotices"
    fi
  else
    swift build --disable-sandbox -c "$configuration" --product SeatSix
    bin_path="$(swift build -c "$configuration" --show-bin-path)"
    cp "$bin_path/SeatSix" "$staging_app/Contents/MacOS/SeatSix"
    cp -R "$bin_path/SeatSix_SeatSixApp.bundle" "$staging_app/Contents/Resources/"
  fi
  /bin/bash scripts/build-icon.sh icon/SeatSix.png "$staging_root" "$staging_app/Contents/Resources/SeatSix.icns"
  cp scripts/Info.plist "$staging_app/Contents/Info.plist"
  if [[ "$distribution" == true ]]; then
    python3 scripts/sign-app.py "$staging_app" --public
    python3 scripts/bundle-media-libraries.py "--verify-$player-app" "$staging_app"
    python3 scripts/publish-app.py "$staging_app" "$output_dir" --public
  else
    python3 scripts/bundle-media-libraries.py "$staging_app"
    cp docs/third-party-media.md "$staging_app/Contents/Resources/Third-Party-Media.md"
    sign_args=("$staging_app" --previous-app "$previous_app")
    if [[ "$signing_mode" == local ]]; then sign_args+=(--local); fi
    python3 scripts/sign-app.py "${sign_args[@]}"
    python3 scripts/publish-app.py "$staging_app" "$output_dir"
  fi
  printf 'Built: %s\n' "$app_path"
}

# macOS has no stock flock command. Hold a Python advisory lock across the whole
# build, including SwiftPM's shared output and publication of the signed bundle.
# exec and the inherited descriptor keep the lock alive for the actual build;
# there is no environment flag or recursive invocation that can skip it.
exec python3 - "$PWD" "$configuration" "$signing_mode" "$(declare -f build_app)" <<'PY'
import fcntl
import os
from pathlib import Path
import sys

lock_dir = Path(sys.argv[1]) / ".runtime"
lock_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
lock_fd = os.open(lock_dir / "build-app.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
os.fchmod(lock_fd, 0o600)
fcntl.flock(lock_fd, fcntl.LOCK_EX)
os.set_inheritable(lock_fd, True)
command = "set -euo pipefail\n" + sys.argv[4] + '\nbuild_app "$1" "$2"\n'
os.execv("/bin/bash", ["/bin/bash", "-c", command, "seatsix-build", sys.argv[2], sys.argv[3]])
PY
