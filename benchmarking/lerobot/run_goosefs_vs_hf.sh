#!/usr/bin/env bash
# A/B: LeRobot batched decode (+ hand-tracking) on HF Hub vs local GooseFS.
#
# Prerequisites:
#   - GooseFS master listening (default localhost:9200)
#   - Dataset mirrored to GooseFS (see mirror_egodex_to_goosefs.sh)
#   - Daft built with GooseFS support: `make build`
#   - Optional hand-tracking: pip install 'daft-physical-ai[mediapipe]'
#
# Usage:
#   ./run_goosefs_vs_hf.sh              # decode sweep + charts
#   ./run_goosefs_vs_hf.sh --with-hand  # also hand-tracking workload
#   ./run_goosefs_vs_hf.sh --decode-only
set -euo pipefail

cd "$(dirname "$0")/../.."
PY=${PY:-.venv/bin/python}
OUT_DIR=${OUT_DIR:-benchmarking/lerobot/goosefs_results}
MASTER=${GOOSEFS_MASTER_ADDR:-localhost:9200}
GFS_DATASET=${GOOSEFS_DATASET:-goosefs://${MASTER}/lerobot/egodex-test}
export GOOSEFS_MASTER_ADDR="${MASTER}"
export GOOSEFS_AUTH_TYPE="${GOOSEFS_AUTH_TYPE:-nosasl}"
# Synchronous write-through (cache + UFS). Required for this cluster / durable reads.
export GOOSEFS_WRITE_TYPE="${GOOSEFS_WRITE_TYPE:-cache_through}"
export DAFT_PROGRESS_BAR=0

WITH_HAND=0
DECODE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --with-hand) WITH_HAND=1 ;;
    --decode-only) DECODE_ONLY=1 ;;
    -h|--help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
  esac
done

mkdir -p "$OUT_DIR"

echo "== machine =="
uname -a || true
"$PY" - <<'PY'
import daft
from daft.io import GooseFSConfig
print(f"daft {daft.__version__}")
print("GooseFSConfig OK:", GooseFSConfig)
PY

echo "== GooseFS dataset =="
echo "GOOSEFS_DATASET=$GFS_DATASET"

echo "== [1/4] decode sweep on HF =="
"$PY" benchmarking/lerobot/goosefs_bench.py decode \
  --backend hf \
  --out "$OUT_DIR/decode_hf.json"

echo "== [2/4] decode sweep on GooseFS (timed; run mirror+load first for warm) =="
"$PY" benchmarking/lerobot/goosefs_bench.py decode \
  --backend goosefs \
  --dataset "$GFS_DATASET" \
  --out "$OUT_DIR/decode_goosefs.json" \
  --verify-hash

echo "== [3/4] chart decode =="
"$PY" benchmarking/lerobot/goosefs_bench.py chart decode \
  "$OUT_DIR/decode_hf.json" "$OUT_DIR/decode_goosefs.json"

if [[ "$WITH_HAND" -eq 1 ]]; then
  echo "== [4/4] hand-tracking HF vs GooseFS =="
  "$PY" benchmarking/lerobot/goosefs_bench.py hand \
    --backend hf \
    --out "$OUT_DIR/hand_hf.json"
  "$PY" benchmarking/lerobot/goosefs_bench.py hand \
    --backend goosefs \
    --dataset "$GFS_DATASET" \
    --out "$OUT_DIR/hand_goosefs.json"
  "$PY" benchmarking/lerobot/goosefs_bench.py chart hand \
    "$OUT_DIR/hand_hf.json" "$OUT_DIR/hand_goosefs.json"
else
  echo "== skip hand-tracking (pass --with-hand) =="
fi

echo
echo "Results in $OUT_DIR/"
ls -la "$OUT_DIR"
echo "Charts in benchmarking/lerobot/charts/"
ls -la benchmarking/lerobot/charts/chart_goosefs_vs_hf_* 2>/dev/null || true
