#!/usr/bin/env bash
# Cover the 4 README charts with GooseFS added:
#   1) sweep 1..10: original@HF, batched@HF, batched@GooseFS
#   2) public 6 datasets: SKIPPED here (needs per-dataset GooseFS mirror)
#   3) scale 100 + 632: batched@HF vs batched@GooseFS
#   4) hand 12 frames: original@HF, batched@HF, batched@GooseFS
#
#   ./run_chart_coverage_goosefs.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
PY=${PY:-.venv/bin/python}
OUT=${OUT_DIR:-benchmarking/lerobot/goosefs_results}
BENCH=benchmarking/lerobot/goosefs_bench.py
ORIG_REV=${ORIG_REV:-0a01463a2~1}
MASTER=${GOOSEFS_MASTER_ADDR:-localhost:9200}
GFS_DATASET=${GOOSEFS_DATASET:-goosefs://${MASTER}/lerobot/egodex-test}

export GOOSEFS_MASTER_ADDR="$MASTER"
export GOOSEFS_AUTH_TYPE="${GOOSEFS_AUTH_TYPE:-nosasl}"
export GOOSEFS_WRITE_TYPE="${GOOSEFS_WRITE_TYPE:-cache_through}"
export DAFT_PROGRESS_BAR=0

mkdir -p "$OUT"
git diff --quiet -- daft/datasets/lerobot.py || { echo "lerobot.py dirty; abort"; exit 1; }
trap 'git checkout -- daft/datasets/lerobot.py; echo "[restored lerobot.py]"' EXIT

echo "original reader: $(git log -1 --format='%h %s' "$ORIG_REV")"
echo "GooseFS: $GFS_DATASET"

# --- Chart 1: original @ HF sweep (hand optional; MediaPipe+old reader may SIGSEGV on AV/cv2 clash) ---
echo "== original reader @ HF: sweep =="
git show "$ORIG_REV:daft/datasets/lerobot.py" > daft/datasets/lerobot.py
"$PY" "$BENCH" decode --backend hf --reader original --label 'original+hf' \
  --out "$OUT/decode_hf_original.json"
set +e
"$PY" "$BENCH" hand --backend hf --reader original --label 'original+hf' \
  --out "$OUT/hand_hf_original.json"
HAND_ORIG_RC=$?
set -e
if [[ "$HAND_ORIG_RC" -ne 0 ]]; then
  echo "WARN: original+hf hand failed (rc=$HAND_ORIG_RC); continuing without it"
fi

# --- restore batched ---
git checkout -- daft/datasets/lerobot.py

# --- Chart 1 + 4: batched @ HF ---
echo "== batched reader @ HF: sweep + hand =="
"$PY" "$BENCH" decode --backend hf --reader batched --label 'batched+hf' \
  --out "$OUT/decode_hf_batched.json"
"$PY" "$BENCH" hand --backend hf --reader batched --label 'batched+hf' \
  --out "$OUT/hand_hf_batched.json"

# --- Chart 1 + 4: batched @ GooseFS ---
echo "== batched reader @ GooseFS: sweep + hand =="
"$PY" "$BENCH" decode --backend goosefs --dataset "$GFS_DATASET" \
  --reader batched --label 'batched+goosefs' \
  --out "$OUT/decode_goosefs_batched.json"
"$PY" "$BENCH" hand --backend goosefs --dataset "$GFS_DATASET" \
  --reader batched --label 'batched+goosefs' \
  --out "$OUT/hand_goosefs_batched.json"

# --- Chart 3: scale 100 / 632 ---
echo "== scale 100 + 632 frames: HF vs GooseFS (batched) =="
"$PY" "$BENCH" decode --backend hf --reader batched --label 'batched+hf' \
  --rows 100,632 --out "$OUT/scale_hf_batched.json"
"$PY" "$BENCH" decode --backend goosefs --dataset "$GFS_DATASET" \
  --reader batched --label 'batched+goosefs' \
  --rows 100,632 --out "$OUT/scale_goosefs_batched.json"

# --- Charts ---
echo "== charts =="
"$PY" "$BENCH" chart decode-multi \
  "$OUT/decode_hf_original.json" "$OUT/decode_hf_batched.json" "$OUT/decode_goosefs_batched.json" \
  --out-name chart_orig_batched_goosefs_decode.png \
  --title 'LeRobot decode: original+HF / batched+HF / batched+GooseFS'

HAND_CHART_ARGS=("$OUT/hand_hf_batched.json" "$OUT/hand_goosefs_batched.json")
if [[ -f "$OUT/hand_hf_original.json" ]]; then
  HAND_CHART_ARGS=("$OUT/hand_hf_original.json" "${HAND_CHART_ARGS[@]}")
fi
"$PY" "$BENCH" chart hand-multi "${HAND_CHART_ARGS[@]}" \
  --out-name chart_orig_batched_goosefs_hand.png

"$PY" "$BENCH" chart scale \
  "$OUT/scale_hf_batched.json" "$OUT/scale_goosefs_batched.json" \
  --out-name chart_goosefs_vs_hf_scale.png

echo
echo "NOTE: Chart-2 (6 public datasets) not run — needs GooseFS mirrors per dataset."
echo "Results: $OUT"
ls -la "$OUT"
ls -la benchmarking/lerobot/charts/chart_orig_batched_goosefs_* benchmarking/lerobot/charts/chart_goosefs_vs_hf_scale.png 2>/dev/null || true
