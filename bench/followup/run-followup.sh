#!/usr/bin/env bash
# The follow-up experiments, in the tss-bench-follow image:
#   bench/followup/run-followup.sh OUTDIR [data] [async]
#
# data   the same ~270 MB dataset held per process (memory), shared through
#        mori, or in a read-only DuckDB file, for 1 process and 2, 4 and 8
#        replicas: scenario Q (half the users filter and aggregate it), plus
#        each configuration's startup time and container memory
# async  the CPU job of scenario B in a shiny::ExtendedTask on mirai daemons,
#        against the synchronous app: one process, one process with 4
#        daemons, 4 replicas, and 4 replicas with 1 daemon each
set -euo pipefail
out=$1; shift
parts=${*:-"data async"}
here=$(cd "$(dirname "$0")/.." && pwd)
export IMAGE=tss-bench-follow

for part in $parts; do
  echo "=== $part $(date -Is)"
  case $part in
    data)
      for cpus in 1 2; do
        jobs=()
        for data in memory mori duckdb; do for cfg in "spike 1" "replicas 2" "replicas 4" "replicas 8"; do jobs+=("$data $cfg"); done; done
        mapfile -t jobs < <(printf '%s\n' "${jobs[@]}" | shuf)
        for job in "${jobs[@]}"; do
          read -r data mode n <<< "$job"
          EXTRA_ENV="-e BENCH_APP=/bench/app-data -e BENCH_DATA_MODE=$data" \
            "$here/run-config.sh" "$cpus" "$mode" "$n" "Q" "20" 2 "$out/data-$data"
        done
      done ;;
    async)
      for cpus in 1 2; do
        jobs=("sync spike 1" "async4 spike 1" "sync replicas 4" "async1 replicas 4")
        mapfile -t jobs < <(printf '%s\n' "${jobs[@]}" | shuf)
        for job in "${jobs[@]}"; do
          read -r variant mode n <<< "$job"
          case $variant in
            sync)   env_args="-e BENCH_APP=/bench/app" ;;
            async4) env_args="-e BENCH_APP=/bench/app-async -e BENCH_DAEMONS=4" ;;
            async1) env_args="-e BENCH_APP=/bench/app-async -e BENCH_DAEMONS=1" ;;
          esac
          EXTRA_ENV="$env_args" "$here/run-config.sh" "$cpus" "$mode" "$n" "B" "10 20 40" 2 "$out/async-$variant"
        done
      done ;;
  esac
done
echo "=== done $(date -Is)"
