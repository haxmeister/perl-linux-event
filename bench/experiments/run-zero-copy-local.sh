#!/usr/bin/env bash
# Research-only file-to-TCP comparison. No sudo or system tuning.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p bench/results/zero-copy
output="bench/results/zero-copy/local-$(date +%Y%m%d-%H%M%S)-$$.jsonl"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cc -O2 -std=c11 -Wall -Wextra -Werror -pthread \
  bench/experiments/zero-copy-tcp.c -o "$tmp_dir/zero-copy-tcp"

repeats=5
if [[ $# -eq 0 ]]; then
  :
elif [[ $# -eq 1 && "$1" == "--quick" ]]; then
  repeats=2
else
  echo "Usage: bash bench/experiments/run-zero-copy-local.sh [--quick]" >&2
  exit 2
fi

echo "Comparing copied pread()/send(), sendfile(), and splice() on localhost TCP"
echo "All transfers are nonblocking and byte-for-byte checked by a TCP receiver."
echo "Run when your system is otherwise idle; no privileged settings required."
echo "Output: $output"
for scenario in '64 20000' '4096 8000' '32768 2000' '204800 400' '1048576 100'; do
  read -r bytes rounds <<< "$scenario"
  echo "Payload=$bytes bytes, repetitions=$repeats, rounds=$rounds"
  "$tmp_dir/zero-copy-tcp" --size "$bytes" --rounds "$rounds" \
    --repeats "$repeats" >> "$output"
done
echo "Backpressure test: payload=32768, receiver pause=40us per read"
"$tmp_dir/zero-copy-tcp" --size 32768 --rounds 1500 \
  --repeats "$repeats" --pressure-us 40 >> "$output"

python3 - "$output" <<'PY'
import collections, json, statistics, sys
rows = [json.loads(s) for s in open(sys.argv[1])]
groups = collections.defaultdict(list)
for r in rows:
    if not r["verified"] or r["bytes"] != r["size"] * r["rounds"]:
        raise SystemExit(f"Invalid transfer: {r}")
    groups[(r["size"], r["pressure_us"], r["mode"])].append(r)
print("\nMedian sender CPU per MiB (smaller is better):")
print(f"{'Payload':>9} {'Pressure':>8} {'Copy':>10} {'sendfile':>10} {'splice':>10} {'sendfile saving':>16}")
for size, pressure in sorted({key[:2] for key in groups}):
    med = {m: statistics.median(r["sender_cpu_ms_per_mib"] for r in groups[(size,pressure,m)])
           for m in ("copy","sendfile","splice")}
    print(f"{size:>9} {pressure:>8} {med['copy']:>10.4f} {med['sendfile']:>10.4f} "
          f"{med['splice']:>10.4f} {(1-med['sendfile']/med['copy'])*100:>+15.1f}%")
print(f"\nVerified all {len(rows)} transfer trials, including TCP payload integrity.")
print(f"Saved: {sys.argv[1]}")
PY
