#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift test --disable-sandbox
python3 -m unittest discover -s tests -v
# The internal checkout also carries the historical browser prototype.
if [[ -d prototype || -f tests/test_prototype_ui.cjs ]]; then
  node --test tests/test_prototype_model.cjs tests/test_prototype_ui.cjs
fi
python3 -m unittest discover -s scripts/integration -p 'test_*.py' -v
