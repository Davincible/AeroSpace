#!/usr/bin/env bash
set -euo pipefail

AEROSPACE=${AEROSPACE:-./.build/debug/aerospace}
LOG_FILE=${LOG_FILE:-/tmp/aerospace_perf.log}
ITER=${ITER:-20}
SLEEP=${SLEEP:-0.02}

if [ ! -x "$AEROSPACE" ]; then
  echo "aerospace binary not found: $AEROSPACE" >&2
  echo "build it with: swift build" >&2
  exit 1
fi

log_time() {
  python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z'))
PY
}

start_time=$(log_time)
: > "$LOG_FILE"

if [ "$#" -gt 0 ]; then
  "$@" || true
else
  for i in $(seq 1 "$ITER"); do
    "$AEROSPACE" focus left >/dev/null 2>&1 || true
    "$AEROSPACE" focus right >/dev/null 2>&1 || true
    "$AEROSPACE" move left >/dev/null 2>&1 || true
    "$AEROSPACE" move right >/dev/null 2>&1 || true
    "$AEROSPACE" workspace $(( (i % 3) + 1 )) >/dev/null 2>&1 || true
    sleep "$SLEEP"
  done
fi

end_time=$(log_time)

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$script_dir/perf-report.py" \
  --since "$start_time" \
  --until "$end_time" \
  --only-slow \
  --group-by category-operation \
  --sort p95 \
  --top 20
