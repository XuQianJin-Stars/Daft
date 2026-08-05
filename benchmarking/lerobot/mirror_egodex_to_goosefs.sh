#!/usr/bin/env bash
# Download pepijn223/egodex-test and mirror it into local GooseFS for benchmarks.
#
#   ./mirror_egodex_to_goosefs.sh
#   LOCAL_DIR=/tmp/lerobot-egodex-test GFS_PATH=/lerobot/egodex-test ./mirror_egodex_to_goosefs.sh
set -euo pipefail

GOOSEFS_HOME=${GOOSEFS_HOME:-/opt/sourcecode/cos/goosefs}
GOOSEFS_BIN=${GOOSEFS_BIN:-$GOOSEFS_HOME/bin/goosefs}
LOCAL_DIR=${LOCAL_DIR:-/tmp/lerobot-egodex-test}
GFS_PATH=${GFS_PATH:-/lerobot/egodex-test}
HF_REPO=${HF_REPO:-pepijn223/egodex-test}
PY=${PY:-/opt/sourcecode/Daft/.venv/bin/python}
HF=${HF:-/opt/sourcecode/Daft/.venv/bin/hf}

if [[ ! -x "$GOOSEFS_BIN" ]]; then
  echo "GooseFS CLI not found: $GOOSEFS_BIN" >&2
  exit 1
fi

echo "== [1/4] download HF dataset $HF_REPO -> $LOCAL_DIR =="
mkdir -p "$LOCAL_DIR"
if [[ ! -f "$LOCAL_DIR/meta/info.json" ]]; then
  "$HF" download "$HF_REPO" --repo-type dataset --local-dir "$LOCAL_DIR"
else
  echo "already present: $LOCAL_DIR/meta/info.json"
fi
du -sh "$LOCAL_DIR"
test -f "$LOCAL_DIR/meta/info.json"
"$PY" - <<PY
import json
info=json.load(open("$LOCAL_DIR/meta/info.json"))
print("codebase_version=", info.get("codebase_version"), "fps=", info.get("fps"))
assert info.get("codebase_version") == "v3.0", info.get("codebase_version")
PY

echo "== [2/4] ensure GooseFS dirs (mkdir creates parents) =="
# Some GooseFS builds reject `mkdir -p`; plain mkdir creates parents.
rm -rf "$LOCAL_DIR/.cache" 2>/dev/null || true
"$GOOSEFS_BIN" fs mkdir "$(dirname "$GFS_PATH")" || true
"$GOOSEFS_BIN" fs mkdir "$GFS_PATH" || true

echo "== [3/4] copyFromLocal meta/data/videos -> $GFS_PATH =="
# Remove previous trees if present. `rm -R` may prompt; feed 'y'.
yes | "$GOOSEFS_BIN" fs rm -R "$GFS_PATH/meta" 2>/dev/null || true
yes | "$GOOSEFS_BIN" fs rm -R "$GFS_PATH/data" 2>/dev/null || true
yes | "$GOOSEFS_BIN" fs rm -R "$GFS_PATH/videos" 2>/dev/null || true
"$GOOSEFS_BIN" fs copyFromLocal "$LOCAL_DIR/meta" "$GFS_PATH/meta"
"$GOOSEFS_BIN" fs copyFromLocal "$LOCAL_DIR/data" "$GFS_PATH/data"
"$GOOSEFS_BIN" fs copyFromLocal "$LOCAL_DIR/videos" "$GFS_PATH/videos"
"$GOOSEFS_BIN" fs ls "$GFS_PATH"
"$GOOSEFS_BIN" fs ls "$GFS_PATH/meta"

echo "== [4/4] load into GooseFS cache (warm) =="
"$GOOSEFS_BIN" fs load "$GFS_PATH" || {
  echo "WARN: 'goosefs fs load' failed; cold-cache first read may be slower" >&2
}

echo
echo "Mirrored LeRobot v3 dataset:"
echo "  local:   $LOCAL_DIR"
echo "  goosefs: goosefs://localhost:9200${GFS_PATH}"
echo "Verify with:"
echo "  $GOOSEFS_BIN fs ls ${GFS_PATH}/meta"
