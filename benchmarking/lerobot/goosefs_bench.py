"""A/B LeRobot decode (+ optional hand-tracking) on HF vs GooseFS.

Fixes the reader to current batched decode and varies only the storage backend,
matching the methodology in docs/research/goosefs-lerobot-acceleration-analysis.md.

Examples:

    # Decode sweep (rows 1..10) on HF Hub
    python goosefs_bench.py decode --backend hf --out results/decode_hf.json

    # Same sweep on GooseFS (warm cache)
    python goosefs_bench.py decode --backend goosefs \\
        --dataset goosefs://localhost:9200/lerobot/egodex-test \\
        --out results/decode_goosefs.json

    # Hand-tracking workload (12 frames + MediaPipe)
    python goosefs_bench.py hand --backend hf --out results/hand_hf.json
    python goosefs_bench.py hand --backend goosefs \\
        --dataset goosefs://localhost:9200/lerobot/egodex-test \\
        --out results/hand_goosefs.json

    # Chart a pair
    python goosefs_bench.py chart decode results/decode_hf.json results/decode_goosefs.json
    python goosefs_bench.py chart hand results/hand_hf.json results/hand_goosefs.json

Environment:
    GOOSEFS_MASTER_ADDR   default master (e.g. localhost:9200)
    GOOSEFS_AUTH_TYPE     simple|nosasl (default nosasl for local clusters)
    GOOSEFS_AUTH_USERNAME optional
    GOOSEFS_WRITE_TYPE    must be synchronous: cache_through (default) or through
                          (async_through is not used for this benchmark)
    DAFT_PROGRESS_BAR=0   recommended for clean timing logs
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any

os.environ.setdefault("DAFT_PROGRESS_BAR", "0")

HERE = Path(__file__).resolve().parent
CHARTS = HERE / "charts"
RESULTS = HERE / "goosefs_results"
DEFAULT_HF_DATASET = "pepijn223/egodex-test"
IMAGE_COLUMN = "observation.image"
SWEEP_ROWS = list(range(1, 11))
HAND_ROWS = 12


def _io_config_for(backend: str):
    import daft
    from daft.io import GooseFSConfig, IOConfig

    if backend == "hf":
        return None
    if backend == "goosefs":
        master = os.environ.get("GOOSEFS_MASTER_ADDR", "localhost:9200")
        auth_type = os.environ.get("GOOSEFS_AUTH_TYPE", "nosasl")
        # Synchronous write-through: cache + persist to UFS. Do not use async_through.
        write_type = os.environ.get("GOOSEFS_WRITE_TYPE", "cache_through")
        if write_type not in ("cache_through", "through"):
            raise ValueError(
                f"GOOSEFS_WRITE_TYPE={write_type!r} must be synchronous "
                f"('cache_through' or 'through'); refuse async_through/must_cache"
            )
        username = os.environ.get("GOOSEFS_AUTH_USERNAME")
        kwargs: dict[str, Any] = {
            "master_addr": master,
            "auth_type": auth_type,
            "write_type": write_type,
            "anonymous": auth_type == "nosasl",
        }
        if username:
            kwargs["auth_username"] = username
            kwargs["anonymous"] = False
        cfg = IOConfig(goosefs=GooseFSConfig(**kwargs))
        daft.set_planning_config(default_io_config=cfg)
        return cfg
    if backend == "file":
        return None
    raise ValueError(f"unknown backend: {backend}")


def _resolve_dataset(backend: str, dataset: str | None) -> str:
    if dataset:
        return dataset
    if backend == "hf":
        return DEFAULT_HF_DATASET
    if backend == "goosefs":
        master = os.environ.get("GOOSEFS_MASTER_ADDR", "localhost:9200")
        return f"goosefs://{master}/lerobot/egodex-test"
    raise ValueError(f"--dataset is required for backend={backend}")


def _sha_image(img: Any) -> str:
    import numpy as np

    arr = np.asarray(img)
    return hashlib.sha256(arr.tobytes()).hexdigest()


def run_decode(
    *,
    backend: str,
    dataset: str,
    rows: list[int],
    out: Path,
    verify_hash: bool,
) -> dict[str, Any]:
    from daft.datasets import lerobot

    io_config = _io_config_for(backend)
    print(f"decode backend={backend} dataset={dataset} rows={rows}", flush=True)

    results = []
    first_hashes: list[str] | None = None
    for n in rows:
        df = lerobot.read(dataset, io_config=io_config, load_video_frames=IMAGE_COLUMN).limit(n)
        t0 = time.perf_counter()
        data = df.select("episode_index", "frame_index", IMAGE_COLUMN).to_pydict()
        wall = time.perf_counter() - t0
        assert len(data["episode_index"]) == n, f"expected {n} rows, got {len(data['episode_index'])}"
        entry: dict[str, Any] = {"rows": n, "wall": wall, "s_per_frame": wall / n}
        if verify_hash:
            hashes = [_sha_image(data[IMAGE_COLUMN][i]) for i in range(n)]
            entry["sha256_prefix"] = [h[:12] for h in hashes]
            if first_hashes is None and n == max(rows):
                first_hashes = hashes
        results.append(entry)
        print(f"  rows={n:3d}  wall={wall:7.2f}s  ({wall / n:5.2f}s/frame)", flush=True)

    payload = {
        "kind": "decode",
        "backend": backend,
        "dataset": dataset,
        "image_column": IMAGE_COLUMN,
        "reader": os.environ.get("LEROBOT_READER", "batched"),
        "label": os.environ.get("BENCH_LABEL"),
        "results": results,
    }
    if payload["label"] is None:
        payload["label"] = f"{payload['reader']}+{backend}"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2, sort_keys=True))
    print(f"wrote {out}", flush=True)
    return payload


def run_hand(
    *,
    backend: str,
    dataset: str,
    n_rows: int,
    out: Path,
) -> dict[str, Any]:
    from daft.datasets import lerobot
    from daft_physical_ai.hands import track_hands

    io_config = _io_config_for(backend)
    print(f"hand backend={backend} dataset={dataset} n_rows={n_rows}", flush=True)

    t0 = time.perf_counter()
    df = lerobot.read(dataset, io_config=io_config, load_video_frames=IMAGE_COLUMN).limit(n_rows)
    df = df.with_column("hands", track_hands(df[IMAGE_COLUMN], method="mediapipe"))
    data = df.select("episode_index", "frame_index", "hands").to_pydict()
    wall = time.perf_counter() - t0

    rows = [
        {
            "episode_index": int(data["episode_index"][i]),
            "frame_index": int(data["frame_index"][i]),
            "n_hands": len(data["hands"][i] or []),
        }
        for i in range(len(data["episode_index"]))
    ]
    rows.sort(key=lambda r: (r["episode_index"], r["frame_index"]))
    assert len(rows) == n_rows, f"expected {n_rows} rows, got {len(rows)}"

    payload = {
        "kind": "hand",
        "backend": backend,
        "dataset": dataset,
        "wall": wall,
        "n_rows": n_rows,
        "rows": rows,
        "reader": os.environ.get("LEROBOT_READER", "batched"),
        "label": os.environ.get("BENCH_LABEL"),
    }
    if payload["label"] is None:
        payload["label"] = f"{payload['reader']}+{backend}"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2, sort_keys=True))
    print(f"OK {backend}: {n_rows} rows in {wall:.1f}s -> {out}", flush=True)
    return payload


def chart_decode(path_a: Path, path_b: Path, out_name: str = "chart_goosefs_vs_hf_decode.png") -> int:
    return chart_decode_multi([path_a, path_b], out_name, title="LeRobot batched decode: HF vs GooseFS")


def chart_decode_multi(
    paths: list[Path],
    out_name: str,
    title: str = "LeRobot decode: original / batched / GooseFS",
) -> int:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    styles = [
        ("o-", "#d62728"),
        ("s-", "#2ca02c"),
        ("^-", "#ff7f0e"),
        ("D-", "#1f77b4"),
    ]
    fig, ax = plt.subplots(figsize=(7.5, 4.5))
    for path, (fmt, color) in zip(paths, styles):
        payload = json.loads(path.read_text())
        label = payload.get("label") or f"{payload['backend']}"
        if payload.get("reader"):
            label = f"{payload['reader']}+{payload['backend']}"
        ax.plot(
            [r["rows"] for r in payload["results"]],
            [r["wall"] for r in payload["results"]],
            fmt,
            color=color,
            label=label,
        )
    ax.set_xlabel("frames decoded")
    ax.set_ylabel("wall time (s)")
    ax.set_title(title)
    ax.legend(fontsize=8)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    CHARTS.mkdir(exist_ok=True)
    out = CHARTS / out_name
    fig.savefig(out, dpi=130)
    print(f"wrote {out.relative_to(HERE)}")
    return 0


def chart_hand(path_a: Path, path_b: Path, out_name: str = "chart_goosefs_vs_hf_hand.png") -> int:
    return chart_hand_multi([path_a, path_b], out_name)


def chart_hand_multi(paths: list[Path], out_name: str = "chart_goosefs_vs_hf_hand.png") -> int:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    payloads = [json.loads(p.read_text()) for p in paths]
    hands_lists = [[r["n_hands"] for r in p.get("rows", [])] for p in payloads]
    if any(h != hands_lists[0] for h in hands_lists[1:]):
        print("WARNING: detected hands differ between runs")

    colors = ["#d62728", "#2ca02c", "#ff7f0e", "#1f77b4"]
    labels = []
    walls = []
    for p in payloads:
        label = p.get("label") or p["backend"]
        if p.get("reader"):
            label = f"{p['reader']}\n+{p['backend']}"
        labels.append(label)
        walls.append(p["wall"])

    fig, ax = plt.subplots(figsize=(8, 4.5))
    bars = ax.bar(labels, walls, color=colors[: len(walls)], width=0.55)
    for bar, wall in zip(bars, walls):
        ax.text(bar.get_x() + bar.get_width() / 2, wall, f"{wall:.1f}s", ha="center", va="bottom")
    ax.set_ylabel("wall time (s)")
    n = payloads[0].get("n_rows", HAND_ROWS)
    ax.set_title(f"Hand-tracking: decode + MediaPipe ({n} frames)\noriginal / batched / GooseFS")
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    CHARTS.mkdir(exist_ok=True)
    out = CHARTS / out_name
    fig.savefig(out, dpi=130)
    print(f"wrote {out.relative_to(HERE)}")
    return 0


def chart_scale(paths: list[Path], out_name: str = "chart_goosefs_vs_hf_scale.png") -> int:
    """Bar chart for scale points (e.g. 100 / 632 frames) across backends."""
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import numpy as np

    payloads = [json.loads(p.read_text()) for p in paths]
    # each payload.results is a list of {rows, wall}
    all_ns = sorted({r["rows"] for p in payloads for r in p["results"]})
    x = np.arange(len(all_ns))
    width = 0.8 / max(len(payloads), 1)
    colors = ["#d62728", "#2ca02c", "#ff7f0e", "#1f77b4"]

    fig, ax = plt.subplots(figsize=(8, 4.5))
    for i, p in enumerate(payloads):
        by_n = {r["rows"]: r["wall"] for r in p["results"]}
        heights = [by_n.get(n, 0.0) for n in all_ns]
        label = p.get("label") or f"{p.get('reader', 'batched')}+{p['backend']}"
        bars = ax.bar(x + i * width, heights, width, label=label, color=colors[i % len(colors)])
        for bar, h in zip(bars, heights):
            if h > 0:
                ax.text(bar.get_x() + bar.get_width() / 2, h, f"{h:.0f}s", ha="center", va="bottom", fontsize=8)

    ax.set_xticks(x + width * (len(payloads) - 1) / 2)
    ax.set_xticklabels([f"{n} frames" + ("\n(full)" if n >= 600 else "") for n in all_ns])
    ax.set_ylabel("wall time (s)")
    ax.set_title("Scaling up egodex-test: HF vs GooseFS (batched)")
    ax.legend()
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    CHARTS.mkdir(exist_ok=True)
    out = CHARTS / out_name
    fig.savefig(out, dpi=130)
    print(f"wrote {out.relative_to(HERE)}")
    return 0


def chart_hand_legacy(path_a: Path, path_b: Path, out_name: str = "chart_goosefs_vs_hf_hand.png") -> int:
    return chart_hand_multi([path_a, path_b], out_name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_dec = sub.add_parser("decode", help="Sweep decode wall time over row counts")
    p_dec.add_argument("--backend", choices=["hf", "goosefs", "file"], required=True)
    p_dec.add_argument("--dataset", default=None)
    p_dec.add_argument("--rows", default=",".join(str(r) for r in SWEEP_ROWS), help="comma-separated row counts")
    p_dec.add_argument("--out", type=Path, required=True)
    p_dec.add_argument("--verify-hash", action="store_true")
    p_dec.add_argument("--warmup", type=int, default=0, help="optional warmup collect of N rows before timing")
    p_dec.add_argument("--reader", default=None, help="tag stored in JSON (original|batched)")
    p_dec.add_argument("--label", default=None, help="legend label override")

    p_hand = sub.add_parser("hand", help="Hand-tracking end-to-end workload")
    p_hand.add_argument("--backend", choices=["hf", "goosefs", "file"], required=True)
    p_hand.add_argument("--dataset", default=None)
    p_hand.add_argument("--n-rows", type=int, default=HAND_ROWS)
    p_hand.add_argument("--out", type=Path, required=True)
    p_hand.add_argument("--reader", default=None)
    p_hand.add_argument("--label", default=None)

    p_chart = sub.add_parser("chart", help="Chart result JSON files")
    p_chart.add_argument("kind", choices=["decode", "hand", "scale", "decode-multi", "hand-multi"])
    p_chart.add_argument("paths", nargs="+", type=Path)
    p_chart.add_argument("--out-name", default=None)
    p_chart.add_argument("--title", default=None)

    args = parser.parse_args()

    if args.cmd == "chart":
        if args.kind == "decode":
            if len(args.paths) < 2:
                print("decode chart needs >=2 paths", flush=True)
                return 1
            return chart_decode(args.paths[0], args.paths[1], args.out_name or "chart_goosefs_vs_hf_decode.png")
        if args.kind == "hand":
            if len(args.paths) < 2:
                print("hand chart needs >=2 paths", flush=True)
                return 1
            return chart_hand(args.paths[0], args.paths[1], args.out_name or "chart_goosefs_vs_hf_hand.png")
        if args.kind == "decode-multi":
            return chart_decode_multi(
                args.paths,
                args.out_name or "chart_orig_batched_goosefs_decode.png",
                title=args.title or "LeRobot decode: original / batched / GooseFS",
            )
        if args.kind == "hand-multi":
            return chart_hand_multi(args.paths, args.out_name or "chart_orig_batched_goosefs_hand.png")
        if args.kind == "scale":
            return chart_scale(args.paths, args.out_name or "chart_goosefs_vs_hf_scale.png")
        return 1

    if args.reader:
        os.environ["LEROBOT_READER"] = args.reader
    if args.label:
        os.environ["BENCH_LABEL"] = args.label

    dataset = _resolve_dataset(args.backend, args.dataset)

    if args.cmd == "decode":
        rows = [int(x) for x in args.rows.split(",") if x.strip()]
        if args.warmup:
            print(f"warmup {args.warmup} rows (not timed)...", flush=True)
            from daft.datasets import lerobot

            io_config = _io_config_for(args.backend)
            lerobot.read(dataset, io_config=io_config, load_video_frames=IMAGE_COLUMN).limit(args.warmup).collect()
        run_decode(
            backend=args.backend,
            dataset=dataset,
            rows=rows,
            out=args.out,
            verify_hash=args.verify_hash,
        )
        return 0

    if args.cmd == "hand":
        run_hand(backend=args.backend, dataset=dataset, n_rows=args.n_rows, out=args.out)
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
