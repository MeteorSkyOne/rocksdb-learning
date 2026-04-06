#!/usr/bin/env bash
# Copyright (c) Meta Platforms, Inc. and affiliates. All Rights Reserved.
#
# Comprehensive benchmark for RocksDB point lookups and range scans.
# Reports: P50, P75, P95, P99, P99.9, P99.99, Max, Min, Avg, StdDev, ops/sec, MB/s
#
# REQUIRE: db_bench binary exists (build with: DEBUG_LEVEL=0 make db_bench -j$(nproc))
#
# Usage:
#   bash tools/benchmark_read_scan.sh
#
# Quick smoke test:
#   NUM_KEYS=100000 DURATION=5 THREAD_COUNTS="1 4" MULTIGET_BATCH_SIZES="16" \
#   SKIP_MIXED=1 DB_DIR=/tmp/rocksdb_smoke bash tools/benchmark_read_scan.sh
#
# All parameters are configurable via environment variables (see below).

set -eo pipefail

# ============================================================================
# Size Constants
# ============================================================================
K=1024
M=$((1024 * K))
G=$((1024 * M))

# ============================================================================
# Configuration (environment variables with defaults)
# ============================================================================

# Paths
DB_DIR="${DB_DIR:-/tmp/rocksdb_bench_read_scan}"
WAL_DIR="${WAL_DIR:-$DB_DIR}"
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/rocksdb_bench_results}"
DB_BENCH_BINARY="${DB_BENCH_BINARY:-./db_bench}"

# Data loading
NUM_KEYS="${NUM_KEYS:-50000000}"
KEY_SIZE="${KEY_SIZE:-16}"
VALUE_SIZE="${VALUE_SIZE:-100}"
COMPRESSION_TYPE="${COMPRESSION_TYPE:-none}"
BLOOM_BITS="${BLOOM_BITS:-10}"
MAX_BACKGROUND_JOBS="${MAX_BACKGROUND_JOBS:-16}"

# Benchmark execution
DURATION="${DURATION:-60}"
THREAD_COUNTS="${THREAD_COUNTS:-1 8 16 32}"
DEFAULT_THREADS="${DEFAULT_THREADS:-16}"

# Cache sizes (bytes)
CACHE_SIZE_DEFAULT="${CACHE_SIZE_DEFAULT:-$((8 * G))}"
CACHE_SIZE_COLD="${CACHE_SIZE_COLD:-$((1 * M))}"
CACHE_SIZE_WARM="${CACHE_SIZE_WARM:-$((1 * G))}"
CACHE_SIZE_HOT="${CACHE_SIZE_HOT:-$((16 * G))}"

# MultiGet
MULTIGET_BATCH_SIZES="${MULTIGET_BATCH_SIZES:-1 16 64 256}"

# Range scan lengths (number of Next() calls per Seek)
SEEK_NEXTS_SHORT="${SEEK_NEXTS_SHORT:-10}"
SEEK_NEXTS_MEDIUM="${SEEK_NEXTS_MEDIUM:-100}"
SEEK_NEXTS_LONG="${SEEK_NEXTS_LONG:-1000}"

# Write pressure rate limit (bytes/sec for background writer)
WRITE_RATE_LIMIT="${WRITE_RATE_LIMIT:-$((10 * M))}"

# Control flags
USE_EXISTING_DB="${USE_EXISTING_DB:-0}"
SKIP_POINT_LOOKUP="${SKIP_POINT_LOOKUP:-0}"
SKIP_RANGE_SCAN="${SKIP_RANGE_SCAN:-0}"
SKIP_MIXED="${SKIP_MIXED:-0}"

# Optional numactl
NUMACTL_CMD=""
if [ -n "${NUMACTL:-}" ]; then
  NUMACTL_CMD="numactl --interleave=all"
fi

# ============================================================================
# Pre-flight checks
# ============================================================================

if [ ! -x "$DB_BENCH_BINARY" ]; then
  echo "ERROR: $DB_BENCH_BINARY not found or not executable."
  echo "Build it with: make clean && DEBUG_LEVEL=0 make db_bench -j\$(nproc)"
  exit 1
fi

mkdir -p "$OUTPUT_DIR" "$DB_DIR"

CSV_FILE="$OUTPUT_DIR/results.csv"
SUMMARY_FILE="$OUTPUT_DIR/summary.txt"

# ============================================================================
# Global results storage (for final summary table)
# ============================================================================
declare -a RESULT_ROWS=()

# ============================================================================
# Signal handling: print partial results on interrupt
# ============================================================================
cleanup() {
  echo ""
  echo "Interrupted. Printing partial results..."
  print_summary_table
  exit 130
}
trap cleanup SIGINT SIGTERM

# ============================================================================
# Utility: human-readable bytes
# ============================================================================
human_bytes() {
  local bytes=$1
  if [ "$bytes" -ge "$G" ]; then
    echo "$(( bytes / G ))GB"
  elif [ "$bytes" -ge "$M" ]; then
    echo "$(( bytes / M ))MB"
  elif [ "$bytes" -ge "$K" ]; then
    echo "$(( bytes / K ))KB"
  else
    echo "${bytes}B"
  fi
}

# ============================================================================
# Utility: parse db_bench output and extract all metrics
# ============================================================================
parse_results() {
  local log_file="$1"
  local bench_name="$2"
  local stats_key="$3"

  # --- Per-operation histogram ---
  # Format: "Percentiles: P50: 11.56 P75: 14.23 P99: 45.67 P99.9: 98.23 P99.99: 145.67"
  local pct_line
  pct_line=$(grep "^Percentiles:" "$log_file" 2>/dev/null | tail -1 || true)

  local p50="N/A" p75="N/A" p99="N/A" p999="N/A" p9999="N/A"
  if [ -n "$pct_line" ]; then
    p50=$(echo "$pct_line" | awk '{print $3}')
    p75=$(echo "$pct_line" | awk '{print $5}')
    p99=$(echo "$pct_line" | awk '{print $7}')
    p999=$(echo "$pct_line" | awk '{print $9}')
    p9999=$(echo "$pct_line" | awk '{print $11}')
  fi

  # Format: "Count: 5000000 Average: 12.3400  StdDev: 5.67"
  local count_line
  count_line=$(grep "^Count:" "$log_file" 2>/dev/null | tail -1 || true)

  local avg="N/A" stddev="N/A" count="N/A"
  if [ -n "$count_line" ]; then
    avg=$(echo "$count_line" | awk '{print $4}')
    stddev=$(echo "$count_line" | awk '{print $6}')
    count=$(echo "$count_line" | awk '{print $2}')
  fi

  # Format: "Min: 2  Median: 11.5600  Max: 156"
  local minmax_line
  minmax_line=$(grep "^Min:" "$log_file" 2>/dev/null | grep "Median:" | grep "Max:" | tail -1 || true)

  local min_val="N/A" max_val="N/A"
  if [ -n "$minmax_line" ]; then
    min_val=$(echo "$minmax_line" | awk '{print $2}')
    max_val=$(echo "$minmax_line" | awk '{print $6}')
  fi

  # --- P95 from --statistics output ---
  # Format: "rocksdb.db.get.micros P50 : 11.56 P95 : 28.90 P99 : 45.67 P100 : 156.00 COUNT : 5000000 SUM : 61700000"
  local p95="N/A"
  if [ -n "$stats_key" ]; then
    local stats_line
    stats_line=$(grep "$stats_key" "$log_file" 2>/dev/null | grep "P95" | tail -1 || true)
    if [ -n "$stats_line" ]; then
      p95=$(echo "$stats_line" | awk '{for(i=1;i<=NF;i++){if($i=="P95"){print $(i+2); exit}}}')
    fi
  fi

  # --- Summary line: ops/sec, MB/s ---
  # Format: "benchname : 12.345 micros/op 81000 ops/sec 60.0 seconds 5000000 operations; 7.7 MB/s"
  local summary_line
  summary_line=$(grep "${bench_name}" "$log_file" 2>/dev/null | grep "ops/sec" | tail -1 || true)

  local ops_sec="N/A" mb_sec="N/A"
  if [ -n "$summary_line" ]; then
    ops_sec=$(echo "$summary_line" | awk '{for(i=1;i<=NF;i++){if($(i+1)=="ops/sec"){print $i; exit}}}')
    mb_sec=$(echo "$summary_line" | awk '{for(i=1;i<=NF;i++){if($(i+1)=="MB/s"){print $i; exit}}}')
    mb_sec="${mb_sec:-N/A}"
  fi

  # Return space-separated values
  echo "$p50 $p75 $p95 $p99 $p999 $p9999 $max_val $min_val $avg $stddev $ops_sec $mb_sec $count"
}

# ============================================================================
# Core: run a single benchmark
# ============================================================================
run_benchmark() {
  local test_name="$1"
  local display_name="$2"
  local bench_name="$3"
  local stats_key="$4"
  local threads="$5"
  local cache_size="$6"
  local batch_size="$7"
  local seek_nexts="$8"
  shift 8
  local extra_args="$*"

  local log_file="${OUTPUT_DIR}/${test_name}.log"
  local timestamp
  timestamp=$(date +%Y-%m-%dT%H:%M:%S)

  echo ""
  echo "=========================================="
  echo "  $display_name"
  echo "  Threads=$threads  Cache=$(human_bytes "$cache_size")  Batch=$batch_size  SeekNexts=$seek_nexts"
  echo "  Started: $timestamp"
  echo "=========================================="

  local duration_flag="--duration=$DURATION"

  local timeout_secs=$((DURATION + 300))

  timeout "$timeout_secs" \
    $NUMACTL_CMD "$DB_BENCH_BINARY" \
    --benchmarks="${bench_name},stats" \
    --use_existing_db=1 \
    --db="$DB_DIR" \
    --wal_dir="$WAL_DIR" \
    --num="$NUM_KEYS" \
    --key_size="$KEY_SIZE" \
    --value_size="$VALUE_SIZE" \
    --compression_type="$COMPRESSION_TYPE" \
    --bloom_bits="$BLOOM_BITS" \
    --histogram=1 \
    --statistics=1 \
    --stats_level=5 \
    --cache_size="$cache_size" \
    --threads="$threads" \
    --batch_size="$batch_size" \
    --seek_nexts="$seek_nexts" \
    --open_files=-1 \
    --verify_checksum=1 \
    --seed="$RANDOM" \
    $duration_flag \
    $extra_args \
    2>&1 | tee "$log_file"

  local exit_code=${PIPESTATUS[0]}

  if [ "$exit_code" -ne 0 ]; then
    echo "ERROR: $test_name failed with exit code $exit_code"
    local error_row="${test_name},${threads},$((cache_size / M)),${batch_size},${seek_nexts},ERROR,ERROR,ERROR,ERROR,ERROR,ERROR,ERROR,ERROR,ERROR,ERROR,ERROR,ERROR,ERROR,${timestamp}"
    echo "$error_row" >> "$CSV_FILE"
    RESULT_ROWS+=("$(printf "%-40s | %s" "$display_name" "ERROR")")
    return 1
  fi

  # Parse all metrics
  local metrics
  metrics=$(parse_results "$log_file" "$bench_name" "$stats_key")

  local p50 p75 p95 p99 p999 p9999 max_val min_val avg stddev ops_sec mb_sec op_count
  read -r p50 p75 p95 p99 p999 p9999 max_val min_val avg stddev ops_sec mb_sec op_count <<< "$metrics"

  # Append to CSV
  local cache_mb=$((cache_size / M))
  echo "${test_name},${threads},${cache_mb},${batch_size},${seek_nexts},${p50},${p75},${p95},${p99},${p999},${p9999},${max_val},${min_val},${avg},${stddev},${ops_sec},${mb_sec},${op_count},${timestamp}" >> "$CSV_FILE"

  # Store for summary table
  local row
  row=$(printf "%-40s | %8s | %8s | %8s | %8s | %8s | %8s | %8s | %6s | %8s | %8s | %9s | %6s" \
    "$display_name" "$p50" "$p75" "$p95" "$p99" "$p999" "$p9999" "$max_val" "$min_val" "$avg" "$stddev" "$ops_sec" "$mb_sec")
  RESULT_ROWS+=("$row")

  echo ""
  echo "  -> ops/sec: $ops_sec | P50: $p50 | P99: $p99 | P99.9: $p999 | Max: $max_val us"
  echo ""
}

# ============================================================================
# Print final summary table
# ============================================================================
print_summary_table() {
  local sep
  sep=$(printf '%0.s=' {1..186})

  {
    echo ""
    echo "$sep"
    echo "RocksDB Read/Scan Benchmark Results  (all latencies in microseconds)"
    echo "$sep"
    printf "%-40s | %8s | %8s | %8s | %8s | %8s | %8s | %8s | %6s | %8s | %8s | %9s | %6s\n" \
      "Test Name" "P50" "P75" "P95" "P99" "P99.9" "P99.99" "Max" "Min" "Avg" "StdDev" "ops/sec" "MB/s"
    local dash
    dash=$(printf '%0.s-' {1..186})
    echo "$dash"

    for row in "${RESULT_ROWS[@]}"; do
      echo "$row"
    done

    echo "$sep"
    echo ""
    echo "Results CSV : $CSV_FILE"
    echo "Detailed logs: $OUTPUT_DIR/*.log"
    echo ""
  } | tee "$SUMMARY_FILE"
}

# ============================================================================
# Phase 0: Data Loading
# ============================================================================
load_data() {
  if [ "$USE_EXISTING_DB" = "1" ]; then
    echo "Skipping data loading (USE_EXISTING_DB=1)"
    return
  fi

  echo ""
  echo "============================================"
  echo "  Phase 0: Loading $NUM_KEYS keys"
  echo "  Key=$KEY_SIZE B  Value=$VALUE_SIZE B  Compression=$COMPRESSION_TYPE"
  echo "  DB: $DB_DIR"
  echo "============================================"

  local log_file="${OUTPUT_DIR}/load.log"

  $NUMACTL_CMD "$DB_BENCH_BINARY" \
    --benchmarks=fillrandom,compact \
    --use_existing_db=0 \
    --db="$DB_DIR" \
    --wal_dir="$WAL_DIR" \
    --num="$NUM_KEYS" \
    --key_size="$KEY_SIZE" \
    --value_size="$VALUE_SIZE" \
    --compression_type="$COMPRESSION_TYPE" \
    --bloom_bits="$BLOOM_BITS" \
    --threads=1 \
    --max_background_jobs="$MAX_BACKGROUND_JOBS" \
    --histogram=1 \
    --disable_wal=0 \
    2>&1 | tee "$log_file"

  echo "Data loading complete. Log: $log_file"
}

# ============================================================================
# Phase 1: Point Lookup Benchmarks
# ============================================================================
run_point_lookups() {
  if [ "$SKIP_POINT_LOOKUP" = "1" ]; then
    echo "Skipping point lookup benchmarks (SKIP_POINT_LOOKUP=1)"
    return
  fi

  echo ""
  echo "============================================"
  echo "  Phase 1: Point Lookup Benchmarks"
  echo "============================================"

  # 1a. Random point lookups -- varying thread counts
  for t in $THREAD_COUNTS; do
    run_benchmark \
      "readrandom_t${t}" \
      "readrandom (${t}T, cache=$(human_bytes "$CACHE_SIZE_DEFAULT"))" \
      "readrandom" \
      "rocksdb.db.get.micros" \
      "$t" "$CACHE_SIZE_DEFAULT" 1 0
  done

  # 1b. Random point lookups -- varying cache sizes
  for label_size in "cold:$CACHE_SIZE_COLD" "warm:$CACHE_SIZE_WARM" "hot:$CACHE_SIZE_HOT"; do
    local label="${label_size%%:*}"
    local size="${label_size##*:}"
    run_benchmark \
      "readrandom_cache_${label}" \
      "readrandom (${DEFAULT_THREADS}T, cache=$(human_bytes "$size") ${label})" \
      "readrandom" \
      "rocksdb.db.get.micros" \
      "$DEFAULT_THREADS" "$size" 1 0
  done

  # 1c. MultiGet with various batch sizes
  for bs in $MULTIGET_BATCH_SIZES; do
    run_benchmark \
      "multiget_bs${bs}" \
      "multireadrandom (${DEFAULT_THREADS}T, batch=$bs)" \
      "multireadrandom" \
      "rocksdb.db.multiget.micros" \
      "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" "$bs" 0 \
      "--multiread_batched=1"
  done

  # 1d. Point lookup on missing keys (bloom filter effectiveness)
  run_benchmark \
    "readmissing" \
    "readmissing (${DEFAULT_THREADS}T, bloom=${BLOOM_BITS}bpk)" \
    "readmissing" \
    "rocksdb.db.get.micros" \
    "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 0

  # 1e. Point lookup under write pressure
  run_benchmark \
    "readwhilewriting" \
    "readwhilewriting (${DEFAULT_THREADS}T, wr=$(human_bytes "$WRITE_RATE_LIMIT")/s)" \
    "readwhilewriting" \
    "rocksdb.db.get.micros" \
    "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 0 \
    "--benchmark_write_rate_limit=$WRITE_RATE_LIMIT"
}

# ============================================================================
# Phase 2: Range Scan Benchmarks
# ============================================================================
run_range_scans() {
  if [ "$SKIP_RANGE_SCAN" = "1" ]; then
    echo "Skipping range scan benchmarks (SKIP_RANGE_SCAN=1)"
    return
  fi

  echo ""
  echo "============================================"
  echo "  Phase 2: Range Scan Benchmarks"
  echo "============================================"

  # 2a. Short/Medium/Long scans with default threads
  for label_nexts in "short:$SEEK_NEXTS_SHORT" "medium:$SEEK_NEXTS_MEDIUM" "long:$SEEK_NEXTS_LONG"; do
    local label="${label_nexts%%:*}"
    local nexts="${label_nexts##*:}"
    run_benchmark \
      "seekrandom_${label}" \
      "seekrandom ${label} (${DEFAULT_THREADS}T, nexts=$nexts)" \
      "seekrandom" \
      "rocksdb.db.seek.micros" \
      "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 "$nexts"
  done

  # 2b. Range scan with varying thread counts (medium scan length)
  for t in $THREAD_COUNTS; do
    # Skip if this duplicates 2a (same thread count and medium nexts)
    if [ "$t" = "$DEFAULT_THREADS" ]; then
      continue
    fi
    run_benchmark \
      "seekrandom_t${t}" \
      "seekrandom (${t}T, nexts=$SEEK_NEXTS_MEDIUM)" \
      "seekrandom" \
      "rocksdb.db.seek.micros" \
      "$t" "$CACHE_SIZE_DEFAULT" 1 "$SEEK_NEXTS_MEDIUM"
  done

  # 2c. Range scan under write pressure
  run_benchmark \
    "seekrandom_while_writing" \
    "seekrandom+write (${DEFAULT_THREADS}T, nexts=$SEEK_NEXTS_MEDIUM)" \
    "seekrandomwhilewriting" \
    "rocksdb.db.seek.micros" \
    "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 "$SEEK_NEXTS_MEDIUM" \
    "--benchmark_write_rate_limit=$WRITE_RATE_LIMIT"

  # 2d. Reverse iteration scans
  for label_nexts in "short:$SEEK_NEXTS_SHORT" "medium:$SEEK_NEXTS_MEDIUM" "long:$SEEK_NEXTS_LONG"; do
    local label="${label_nexts%%:*}"
    local nexts="${label_nexts##*:}"
    run_benchmark \
      "reverse_${label}" \
      "reverse scan ${label} (${DEFAULT_THREADS}T, nexts=$nexts)" \
      "seekrandom" \
      "rocksdb.db.seek.micros" \
      "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 "$nexts" \
      "--reverse_iterator=1"
  done

  # 2e. Prefix-based scan
  run_benchmark \
    "seekrandom_prefix" \
    "seekrandom prefix (${DEFAULT_THREADS}T, nexts=$SEEK_NEXTS_MEDIUM)" \
    "seekrandom" \
    "rocksdb.db.seek.micros" \
    "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 "$SEEK_NEXTS_MEDIUM" \
    "--auto_prefix_mode=1 --prefix_size=8"
}

# ============================================================================
# Phase 3: Mixed Workload Benchmarks
# ============================================================================
run_mixed_workloads() {
  if [ "$SKIP_MIXED" = "1" ]; then
    echo "Skipping mixed workload benchmarks (SKIP_MIXED=1)"
    return
  fi

  echo ""
  echo "============================================"
  echo "  Phase 3: Mixed Workload Benchmarks"
  echo "============================================"

  # 3a. 90% read / 10% write
  run_benchmark \
    "mixed_90read_10write" \
    "mixed 90%read/10%write (${DEFAULT_THREADS}T)" \
    "readrandomwriterandom" \
    "rocksdb.db.get.micros" \
    "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 0 \
    "--readwritepercent=90"

  # 3b. 50% read / 50% write
  run_benchmark \
    "mixed_50read_50write" \
    "mixed 50%read/50%write (${DEFAULT_THREADS}T)" \
    "readrandomwriterandom" \
    "rocksdb.db.get.micros" \
    "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 0 \
    "--readwritepercent=50"

  # 3c. Reads while scanning
  run_benchmark \
    "readwhilescanning" \
    "readwhilescanning (${DEFAULT_THREADS}T)" \
    "readwhilescanning" \
    "rocksdb.db.get.micros" \
    "$DEFAULT_THREADS" "$CACHE_SIZE_DEFAULT" 1 0
}

# ============================================================================
# Main
# ============================================================================

echo ""
echo "============================================"
echo "  RocksDB Read/Scan Benchmark Suite"
echo "============================================"
echo "  DB_DIR         : $DB_DIR"
echo "  WAL_DIR        : $WAL_DIR"
echo "  OUTPUT_DIR     : $OUTPUT_DIR"
echo "  NUM_KEYS       : $NUM_KEYS"
echo "  KEY_SIZE       : $KEY_SIZE"
echo "  VALUE_SIZE     : $VALUE_SIZE"
echo "  COMPRESSION    : $COMPRESSION_TYPE"
echo "  BLOOM_BITS     : $BLOOM_BITS"
echo "  DURATION       : ${DURATION}s per benchmark"
echo "  THREAD_COUNTS  : $THREAD_COUNTS"
echo "  DEFAULT_THREADS: $DEFAULT_THREADS"
echo "  CACHE_DEFAULT  : $(human_bytes "$CACHE_SIZE_DEFAULT")"
echo "  DB_BENCH       : $DB_BENCH_BINARY"
echo "============================================"
echo ""

# Initialize CSV with header
echo "test_name,threads,cache_mb,batch_size,seek_nexts,p50_us,p75_us,p95_us,p99_us,p999_us,p9999_us,max_us,min_us,avg_us,stddev_us,ops_sec,mb_sec,count,timestamp" > "$CSV_FILE"

# Run all phases
load_data
run_point_lookups
run_range_scans
run_mixed_workloads

# Print final summary
print_summary_table

echo "Benchmark suite complete."
