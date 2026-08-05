#!/usr/bin/env bash
# Cold-cache GooseFS timings (no fs load). Evicts worker cache before each timed run.
#
#   ./run_goosefs_cold.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
PY=${PY:-.venv/bin/python}
OUT=${OUT_DIR:-benchmarking/lerobot/goosefs_results}
BENCH=benchmarking/lerobot/goosefs_bench.py
GOOSEFS_HOME=${GOOSEFS_HOME:-/opt/sourcecode/cos/goosefs}
GFS_BIN=${GOOSEFS_BIN:-$GOOSEFS_HOME/bin/goosefs}
GFS_PATH=${GFS_PATH:-/lerobot/egodex-test}
MASTER=${GOOSEFS_MASTER_ADDR:-localhost:9200}
GFS_DATASET=${GOOSEFS_DATASET:-goosefs://${MASTER}${GFS_PATH}}

export GOOSEFS_MASTER_ADDR="$MASTER"
export GOOSEFS_AUTH_TYPE="${GOOSEFS_AUTH_TYPE:-nosasl}"
export GOOSEFS_WRITE_TYPE="${GOOSEFS_WRITE_TYPE:-cache_through}"
export DAFT_PROGRESS_BAR=0

mkdir -p "$OUT"

free_cache() {
  echo "== fs free -f $GFS_PATH =="
  "$GFS_BIN" fs free -f "$GFS_PATH" || true
  # Confirm MP4 is no longer fully in GooseFS
  "$GFS_BIN" fs stat "$GFS_PATH/videos/observation.image/chunk-000/file-000.mp4" 2>&1 \
    | tr ',' '\n' | rg -i 'inGooseFSPercentage|length=' | head -5 || true
}

echo "GooseFS cold bench dataset=$GFS_DATASET"

# --- cold decode sweep 1..10 (cache warms within the sweep after first open) ---
free_cache
"$PY" "$BENCH" decode --backend goosefs --dataset "$GFS_DATASET" \
  --reader batched --label 'cold (after fs free)' \
  --out "$OUT/decode_goosefs_cold.json"

# --- cold hand (fresh free so MediaPipe path starts cold) ---
free_cache
set +e
"$PY" "$BENCH" hand --backend goosefs --dataset "$GFS_DATASET" \
  --reader batched --label 'cold (after fs free)' \
  --out "$OUT/hand_goosefs_cold.json"
HAND_RC=$?
set -e
if [[ "$HAND_RC" -ne 0 ]]; then
  echo "WARN: cold hand failed rc=$HAND_RC"
fi

# --- cold scale: free before 100, free before 632 ---
free_cache
"$PY" "$BENCH" decode --backend goosefs --dataset "$GFS_DATASET" \
  --reader batched --label 'cold (after fs free)' \
  --rows 100 --out "$OUT/scale_goosefs_cold_100.json"
free_cache
"$PY" "$BENCH" decode --backend goosefs --dataset "$GFS_DATASET" \
  --reader batched --label 'cold (after fs free)' \
  --rows 632 --out "$OUT/scale_goosefs_cold_632.json"

# Merge scale cold into one JSON for charting
"$PY" - <<PY
import json
from pathlib import Path
out = Path("$OUT")
a = json.loads((out / "scale_goosefs_cold_100.json").read_text())
b = json.loads((out / "scale_goosefs_cold_632.json").read_text())
merged = {
    "kind": "decode",
    "backend": "goosefs",
    "dataset": a["dataset"],
    "reader": "batched",
    "label": "cold (after fs free)",
    "cache": "cold",
    "results": a["results"] + b["results"],
}
(out / "scale_goosefs_cold.json").write_text(json.dumps(merged, indent=2, sort_keys=True))
print("wrote", out / "scale_goosefs_cold.json")
PY

# Charts: warm vs cold (reuse prior warm JSONs if present)
WARM_DEC="$OUT/decode_goosefs_batched.json"
[[ -f "$WARM_DEC" ]] || WARM_DEC="$OUT/decode_goosefs.json"
WARM_SCALE="$OUT/scale_goosefs_batched.json"
WARM_HAND="$OUT/hand_goosefs_batched.json"
[[ -f "$WARM_HAND" ]] || WARM_HAND="$OUT/hand_goosefs.json"

# Ensure warm files carry distinct legend labels
for f in "$WARM_DEC" "$WARM_SCALE" "$WARM_HAND"; do
  [[ -f "$f" ]] || continue
  "$PY" - "$f" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
d = json.loads(p.read_text())
d["label"] = "warm (fs load)"
p.write_text(json.dumps(d, indent=2, sort_keys=True))
PY
done

"$PY" "$BENCH" chart decode-multi \
  "$WARM_DEC" "$OUT/decode_goosefs_cold.json" \
  --out-name chart_goosefs_warm_vs_cold_decode.png \
  --title 'GooseFS batched decode: warm (fs load) vs cold (after fs free)'

if [[ -f "$WARM_SCALE" && -f "$OUT/scale_goosefs_cold.json" ]]; then
  "$PY" "$BENCH" chart scale \
    "$WARM_SCALE" "$OUT/scale_goosefs_cold.json" \
    --out-name chart_goosefs_warm_vs_cold_scale.png
fi

if [[ -f "$WARM_HAND" && -f "$OUT/hand_goosefs_cold.json" ]]; then
  "$PY" "$BENCH" chart hand-multi \
    "$WARM_HAND" "$OUT/hand_goosefs_cold.json" \
    --out-name chart_goosefs_warm_vs_cold_hand.png
fi

echo
echo "Cold results in $OUT"
ls -la "$OUT"/decode_goosefs_cold.json "$OUT"/hand_goosefs_cold.json "$OUT"/scale_goosefs_cold.json 2>/dev/null || true
ls -la benchmarking/lerobot/charts/chart_goosefs_warm_vs_cold_* 2>/dev/null || true
