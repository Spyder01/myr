#!/bin/sh
# Myr benchmark runner
# Usage: ./benchmarks/run.sh
# Builds with -o:speed, times each benchmark 3x, checks for regressions vs results.bench
# Format of results.bench: name, avg_ms, avg_kib

set -e

cd "$(dirname "$0")/.."

BENCH_FILE="benchmarks/results.bench"
RUNS=3
MARGIN=2.0   # regression threshold in percent

echo "building myr..."
/Users/suhanj/.lang/Odin/odin build . -o:speed -out:myr-bench
echo ""

> /tmp/myr_new_bench

run_bench() {
    name=$1
    file=$2
    expected=$3

    echo "=== $name ==="

    total_ms=0
    total_mem=0
    for i in $(seq 1 $RUNS); do
        /usr/bin/time -l ./myr-bench "$file" > /tmp/myr_out 2>/tmp/myr_time_out
        t_ms=$(grep real /tmp/myr_time_out | awk '{printf "%.0f", $1 * 1000}')
        rss=$(grep "maximum resident set size" /tmp/myr_time_out | awk '{printf "%.0f", $1 / 1024}')
        echo "  run $i: ${t_ms}ms  mem: ${rss} KiB"
        total_ms=$((total_ms + t_ms))
        total_mem=$((total_mem + rss))
    done

    avg_ms=$((total_ms / RUNS))
    avg_mem=$((total_mem / RUNS))
    echo "  avg: ${avg_ms}ms  mem: ${avg_mem} KiB"

    actual=$(cat /tmp/myr_out)
    if [ "$actual" = "$expected" ]; then
        echo "  output: $actual ✓"
    else
        echo "  output: $actual (expected $expected) ✗"
    fi

    prev_line=$(grep "^$name," "$BENCH_FILE" 2>/dev/null || true)
    if [ -n "$prev_line" ]; then
        prev_ms=$(echo  "$prev_line" | awk -F',' '{gsub(/ /,"",$2); print $2}')
        prev_mem=$(echo "$prev_line" | awk -F',' '{gsub(/ /,"",$3); print $3}')
        awk -v name="$name" \
            -v new_ms="$avg_ms"   -v old_ms="$prev_ms" \
            -v new_mem="$avg_mem" -v old_mem="$prev_mem" \
            -v margin="$MARGIN" 'BEGIN {
            perf_pct = (new_ms  - old_ms)  / (old_ms  + 0.001) * 100
            mem_pct  = (new_mem - old_mem) / (old_mem + 0.001) * 100
            perf_sym = (perf_pct > margin) ? "⚠ PERF REGRESSION" : "✓ perf"
            mem_sym  = (mem_pct  > margin) ? "⚠ MEM  REGRESSION" : "✓ mem "
            printf "  %s: %dms vs %dms (%+.1f%%)\n",  perf_sym, new_ms,  old_ms,  perf_pct
            printf "  %s: %d KiB vs %d KiB (%+.1f%%)\n", mem_sym, new_mem, old_mem, mem_pct
        }'
    else
        echo "  (no previous result — establishing baseline)"
    fi

    echo "$name, $avg_ms, $avg_mem" >> /tmp/myr_new_bench
    echo ""
}

run_bench "fib"          "benchmarks/fib.myr"          "832040"
run_bench "loop"         "benchmarks/loop.myr"         "499999500000"
run_bench "calls"        "benchmarks/calls.myr"        "4999950000"
run_bench "primes"       "benchmarks/primes.myr"       "1229"
run_bench "for_while"    "benchmarks/for_while.myr"    "499999500000"
run_bench "for_infinite" "benchmarks/for_infinite.myr" "499999500000"
run_bench "for_c_style"  "benchmarks/for_c_style.myr"  "499999500000"
run_bench "str_compare"  "benchmarks/str_compare.myr"  "1000000"
run_bench "str_concat"   "benchmarks/str_concat.myr"   "100000"

cp /tmp/myr_new_bench "$BENCH_FILE"
echo "results saved to $BENCH_FILE"

rm -f myr-bench
