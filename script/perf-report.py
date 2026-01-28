#!/usr/bin/env python3
import argparse
import re
import sys
from datetime import datetime, timezone, timedelta
from typing import Dict, List, Optional


LINE_RE = re.compile(r"^\[(?P<ts>[^\]]+)\] \[(?P<cat>[^\]]+)\] (?P<body>.*)$")
ELAPSED_RE = re.compile(r":\s+(?P<elapsed>[0-9.]+)ms")
WID_RE = re.compile(r"wid=(\d+)")


def parse_ts(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value)


def parse_time_arg(value: Optional[str], base_date: datetime) -> Optional[datetime]:
    if value is None:
        return None
    if "T" in value or "-" in value:
        return parse_ts(value)
    parts = value.split(":")
    if len(parts) not in (2, 3):
        raise ValueError(f"invalid time format: {value}")
    hour = int(parts[0])
    minute = int(parts[1])
    second = int(parts[2]) if len(parts) == 3 else 0
    return datetime(
        base_date.year,
        base_date.month,
        base_date.day,
        hour,
        minute,
        second,
        tzinfo=timezone.utc,
    )


def percentile(values: List[float], pct: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    if len(values) == 1:
        return values[0]
    idx = (len(values) - 1) * pct
    lo = int(idx)
    hi = min(lo + 1, len(values) - 1)
    if lo == hi:
        return values[lo]
    frac = idx - lo
    return values[lo] + (values[hi] - values[lo]) * frac


def parse_line(line: str):
    m = LINE_RE.match(line)
    if not m:
        return None
    ts = parse_ts(m.group("ts"))
    cat = m.group("cat")
    body = m.group("body").strip()
    slow = "[SLOW]" in body
    warn = "[WARN]" in body
    elapsed = None
    op = body
    m2 = ELAPSED_RE.search(body)
    if m2:
        elapsed = float(m2.group("elapsed"))
        op = body[: m2.start()].strip()
    wid = None
    m3 = WID_RE.search(body)
    if m3:
        wid = m3.group(1)
    return {
        "ts": ts,
        "cat": cat,
        "body": body,
        "op": op,
        "elapsed": elapsed,
        "slow": slow,
        "warn": warn,
        "wid": wid,
        "raw": line.rstrip("\n"),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze AeroSpace perf logs")
    parser.add_argument("--log", default="/tmp/aerospace_perf.log", help="log file path")
    parser.add_argument("--since", help="start time (HH:MM[:SS] or ISO8601)")
    parser.add_argument("--until", help="end time (HH:MM[:SS] or ISO8601)")
    parser.add_argument("--category", action="append", help="category filter (repeatable)")
    parser.add_argument("--only-slow", action="store_true", help="only include [SLOW] lines")
    parser.add_argument("--raw", action="store_true", help="print raw lines only")
    parser.add_argument("--top", type=int, default=10, help="top N groups or lines")
    parser.add_argument(
        "--group-by",
        choices=["category", "operation", "window", "category-operation"],
        default="category-operation",
        help="grouping for summary",
    )
    parser.add_argument(
        "--sort",
        choices=["avg", "max", "p95", "count"],
        default="p95",
        help="sort key for summary",
    )
    args = parser.parse_args()

    try:
        with open(args.log, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"log file not found: {args.log}", file=sys.stderr)
        return 2

    records = [r for r in (parse_line(line) for line in lines) if r]
    if not records:
        print("no parseable log lines", file=sys.stderr)
        return 1

    base_date = records[0]["ts"]
    try:
        since_dt = parse_time_arg(args.since, base_date)
        until_dt = parse_time_arg(args.until, base_date)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    if since_dt and until_dt and until_dt < since_dt:
        until_dt = until_dt + timedelta(days=1)

    categories = set(args.category or [])

    def in_range(r):
        if since_dt and r["ts"] < since_dt:
            return False
        if until_dt and r["ts"] > until_dt:
            return False
        if categories and r["cat"] not in categories:
            return False
        if args.only_slow and not r["slow"]:
            return False
        return True

    filtered = [r for r in records if in_range(r)]

    if args.raw:
        for r in filtered:
            print(r["raw"])
        return 0

    measured = [r for r in filtered if r["elapsed"] is not None]
    slow = [r for r in measured if r["slow"]]
    warn = [r for r in filtered if r["warn"]]

    if since_dt or until_dt:
        print(f"range: {since_dt or '-'} to {until_dt or '-'}")
    print(f"lines: {len(filtered)}  measured: {len(measured)}  slow: {len(slow)}  warn: {len(warn)}")

    if not measured:
        return 0

    stats: Dict[str, List[float]] = {}

    def group_key(r):
        if args.group_by == "category":
            return r["cat"]
        if args.group_by == "operation":
            return r["op"]
        if args.group_by == "window":
            return r["wid"] or "unknown"
        return f"{r['cat']} {r['op']}"

    for r in measured:
        key = group_key(r)
        stats.setdefault(key, []).append(r["elapsed"])

    def sort_key(item):
        values = item[1]
        if args.sort == "avg":
            return sum(values) / len(values)
        if args.sort == "max":
            return max(values)
        if args.sort == "count":
            return len(values)
        return percentile(values, 0.95)

    items = sorted(stats.items(), key=sort_key, reverse=True)[: args.top]

    print("\nsummary:")
    print("  key | count | avg | p95 | max")
    for key, values in items:
        avg = sum(values) / len(values)
        p95 = percentile(values, 0.95)
        mx = max(values)
        print(f"  {key} | {len(values)} | {avg:.2f} | {p95:.2f} | {mx:.2f}")

    slowest = sorted(measured, key=lambda r: r["elapsed"], reverse=True)[: args.top]
    print("\nslowest:")
    for r in slowest:
        ts = r["ts"].isoformat().replace("+00:00", "Z")
        print(f"  {ts} [{r['cat']}] {r['op']} -> {r['elapsed']:.3f}ms")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
