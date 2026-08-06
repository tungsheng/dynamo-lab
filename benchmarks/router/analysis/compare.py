#!/usr/bin/env python3
"""Compare aiperf results across router-benchmark arms (ADR 0010).

Reads a results directory laid out one subdir per run, each holding an aiperf export:

    results/
      kv-credit-1/profile_export_aiperf.json
      kv-credit-2/profile_export_aiperf.json
      kv-credit-4/profile_export_aiperf.json
      session/profile_export_aiperf.json
      round-robin/profile_export_aiperf.json
      load-aware/profile_export_aiperf.json

and prints a table of the serving metrics per arm, so you can read off (a) where kv
underperforms session and (b) how far raising --router-kv-overlap-score-credit closes the gap.

The mocker yields RELATIVE orderings, not a specific GPU's absolute latency (ADR 0010) — read
the columns as a comparison between policies, not as production numbers. There is no scalar
cache-hit-rate gauge; TTFT is the proxy (a prefix hit shrinks effective prefill ISL -> lower TTFT).

Usage:  python3 compare.py results/
"""
import argparse
import json
import sys
from pathlib import Path

# Confirmed against aiperf 0.10.0's profile_export_aiperf.json (live 2026-08-06): each metric is a
# TOP-LEVEL key -> {unit, avg, p50, p90, p95, p99, min, max, std, count}. There is NO
# `time_per_output_token` key — aiperf reports per-token cost as `inter_token_latency`; throughput
# metrics carry only `avg`.
METRICS = [
    ("time_to_first_token", "TTFT ms"),
    ("inter_token_latency", "ITL ms"),
    ("request_latency", "E2EL ms"),
    ("request_throughput", "req/s"),
]


def load_stat(export: dict, key: str, stat: str = "avg"):
    """One stat for one metric. Metrics live at the top level; throughput metrics have only avg,
    so fall back to avg when the requested percentile is absent."""
    m = export.get(key) if isinstance(export, dict) else None
    if not isinstance(m, dict):
        return None
    v = m.get(stat)
    return v if v is not None else m.get("avg")


def main() -> int:
    ap = argparse.ArgumentParser(description="Compare aiperf results across router arms.")
    ap.add_argument("results_dir", type=Path)
    ap.add_argument("--stat", default="avg", help="which stat to show (avg|p50|p90|p99)")
    args = ap.parse_args()

    runs = sorted(p.parent.name for p in args.results_dir.glob("*/profile_export_aiperf.json"))
    if not runs:
        print(f"no profile_export_aiperf.json under {args.results_dir}/*/", file=sys.stderr)
        return 1

    def fmt(v):
        return f"{v:.1f}" if isinstance(v, (int, float)) else "n/a"

    header = ["arm"] + [label for _, label in METRICS]
    print("  ".join(f"{h:>18}" for h in header))
    for run in runs:
        export = json.loads(
            (args.results_dir / run / "profile_export_aiperf.json").read_text()
        )
        row = [run] + [fmt(load_stat(export, key, args.stat)) for key, _ in METRICS]
        print("  ".join(f"{c:>18}" for c in row))

    print("\nCompare kv-credit-* vs the cache-blind floors (round-robin / load-aware): lower kv TTFT")
    print("means the router is exploiting prefix locality, and raising overlap-credit should widen")
    print("that gap (ADR 0010). If the rows are equal, routing is not yet discriminating — see the")
    print("README live-findings note (block-size alignment, --router-predicted-ttl-secs).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
