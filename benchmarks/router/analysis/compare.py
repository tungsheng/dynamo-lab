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

# VERIFY (live): the exact aiperf JSON schema. aiperf reports per-metric stats (avg/p50/p90/
# p99). Adjust these key paths to match profile_export_aiperf.json from the pinned aiperf.
METRICS = [
    ("time_to_first_token", "TTFT ms"),
    ("inter_token_latency", "ITL ms"),
    ("time_per_output_token", "TPOT ms"),
    ("request_latency", "E2EL ms"),
]


def load_stat(export: dict, key: str, stat: str = "avg"):
    """Best-effort pull of one stat for one metric; tolerant of schema drift (VERIFY)."""
    node = export.get("records", export).get(key) if isinstance(export, dict) else None
    if isinstance(node, dict):
        return node.get(stat, node.get("value"))
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Compare aiperf results across router arms.")
    ap.add_argument("results_dir", type=Path)
    ap.add_argument("--stat", default="avg", help="which stat to show (avg|p50|p90|p99)")
    args = ap.parse_args()

    runs = sorted(p.parent.name for p in args.results_dir.glob("*/profile_export_aiperf.json"))
    if not runs:
        print(f"no profile_export_aiperf.json under {args.results_dir}/*/", file=sys.stderr)
        return 1

    header = ["arm"] + [label for _, label in METRICS]
    print("  ".join(f"{h:>18}" for h in header))
    for run in runs:
        export = json.loads(
            (args.results_dir / run / "profile_export_aiperf.json").read_text()
        )
        row = [run] + [
            f"{load_stat(export, key, args.stat):.1f}"
            if isinstance(load_stat(export, key, args.stat), (int, float))
            else "n/a"
            for key, _ in METRICS
        ]
        print("  ".join(f"{c:>18}" for c in row))

    print("\nRead kv-credit-* vs session: if a high-credit kv row matches session on TTFT,")
    print("the hypothesis holds — overlap weight closes the prefill cache-locality gap (ADR 0010).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
