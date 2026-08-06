#!/usr/bin/env python3
"""Generate a session-grouped mooncake_trace for the router benchmark's sticky/kv arms.

The stock Mooncake FAST'25 toolagent trace is single-turn (rows carry no ``session_id``), so
session-affinity routing has nothing to pin and the kv-vs-sticky comparison can't run (ADR 0010,
Live findings 2026-08-06). This emits a SYNTHETIC multi-turn trace: each session shares a growing
prefix across its turns — the agentic workload where sticky routing is near-optimal (every turn
after the first is a guaranteed cache hit on the worker the session is pinned to) and the KV router
must reconstruct that locality to match it.

Output format (aiperf ``--custom-dataset-type mooncake_trace``): one JSON object per line —
``session_id, input_length, output_length, hash_ids, delay`` (delay omitted on a session's first
turn). Same-``session_id`` rows replay sequentially as one conversation; ``hash_ids`` encode shared
prefix blocks (shared ids => shared prefix), and each turn's ids are a PREFIX-extension of the
previous turn's, so aiperf materializes matching, growing token prefixes.

The knobs make the workload tunable for the discrimination the first live run lacked:
  --sessions/--turns    how many conversations and how long (concurrency x reuse)
  --system-blocks       per-session stable prefix (the thing sticky pins, kv must find)
  --shared-system-blocks blocks shared across ALL sessions (a global system prompt)
  --turn-blocks         new context each turn adds

Usage:
  python make_session_trace.py --sessions 200 --turns 5 > trace.jsonl

VERIFY (live): that aiperf's mooncake loader materializes shared-``hash_ids`` rows as byte-identical
token prefixes at the engine block size — i.e. that the router actually sees the overlap. Confirm on
the next live run (align --block-size with the mocker/router KV block size).
"""
import argparse
import json
import sys


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--sessions", type=int, default=200, help="number of conversations")
    ap.add_argument("--turns", type=int, default=5, help="turns per conversation")
    ap.add_argument("--block-size", type=int, default=512,
                    help="tokens per hash block (mooncake trace convention; input_length = blocks * this)")
    ap.add_argument("--system-blocks", type=int, default=4,
                    help="per-session stable prefix blocks (sticky pins these; kv must rediscover them)")
    ap.add_argument("--shared-system-blocks", type=int, default=1,
                    help="blocks shared across ALL sessions (a global system prompt) for cross-session locality")
    ap.add_argument("--turn-blocks", type=int, default=1, help="new blocks each turn appends")
    ap.add_argument("--output-length", type=int, default=64, help="output tokens per turn")
    ap.add_argument("--delay-ms", type=int, default=0, help="think time before each non-first turn")
    return ap.parse_args(argv)


def generate(args, out):
    """Emit the trace as JSONL to `out`. Block ids are globally unique except the shared-system
    block ids, which are identical for every session (that is what creates cross-session overlap)."""
    shared = list(range(args.shared_system_blocks))
    next_id = args.shared_system_blocks
    for s in range(args.sessions):
        sys_blocks = list(range(next_id, next_id + args.system_blocks))
        next_id += args.system_blocks
        prefix = shared + sys_blocks  # this session's stable prefix: global + private system
        for t in range(args.turns):
            new_blocks = list(range(next_id, next_id + args.turn_blocks))
            next_id += args.turn_blocks
            prefix = prefix + new_blocks  # conversation grows; prior turns are a prefix of this one
            row = {
                "session_id": f"s{s:05d}",
                "input_length": len(prefix) * args.block_size,
                "output_length": args.output_length,
                "hash_ids": list(prefix),
            }
            if t > 0 and args.delay_ms:
                row["delay"] = args.delay_ms
            out.write(json.dumps(row) + "\n")


def main(argv=None):
    args = parse_args(argv)
    generate(args, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
