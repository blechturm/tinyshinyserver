#!/usr/bin/env bash
# The mizu experiments, in the tss-bench-mizu image:
#   1. transport microbenchmark on 1 and 2 vCPUs
#   2. control plane: 4 replicas with least_connections, with least_connections
#      and mizu telemetry, and with workload_aware and mizu telemetry, against
#      upstream, under session churn
#   3. idle consumption of 8 replicas with and without telemetry
#   4. worker death: detection and recovery with and without telemetry
#   bench/mizu/run-mizu.sh OUTDIR
set -euo pipefail
export MSYS_NO_PATHCONV=1
out=$1
here=$(cd "$(dirname "$0")/.." && pwd)
bench_dir=$(cygpath -m "$here" 2>/dev/null || echo "$here")
export IMAGE=tss-bench-mizu
mkdir -p "$out/transport"
out_dir=$(cd "$out" && (cygpath -m "$PWD" 2>/dev/null || pwd))

echo "=== transport $(date -Is)"
for cpus in 1 2; do for rep in 1 2 3; do
  docker run --rm --cpuset-cpus="4-$((3 + cpus))" -v "$out_dir/transport:/out" --entrypoint Rscript "$IMAGE" \
    /bench/mizu/transport-bench.R "/out/transport_c${cpus}_r${rep}.csv" "c$cpus" > "$out/transport/transport_c${cpus}_r${rep}.txt" 2>&1
done; done

echo "=== control plane $(date -Is)"
export LOADGEN_ARGS="--session-ops 5"
for cpus in 1 2; do
  jobs=(plain mizu aware upstream)
  mapfile -t jobs < <(printf '%s\n' "${jobs[@]}" | shuf)
  for job in "${jobs[@]}"; do
    case $job in
      plain)    "$here/run-config.sh" "$cpus" replicas 4 "B C" "20 80" 3 "$out/control-r4-lc" ;;
      mizu)     EXTRA_ENV="-e TSS_REPLICA_TELEMETRY=mizu" "$here/run-config.sh" "$cpus" replicas 4 "B C" "20 80" 3 "$out/control-r4-lc-mizu" ;;
      aware)    EXTRA_ENV="-e TSS_REPLICA_TELEMETRY=mizu" SCHEDULER=workload_aware "$here/run-config.sh" "$cpus" replicas 4 "B C" "20 80" 3 "$out/control-r4-wa-mizu" ;;
      upstream) "$here/run-config.sh" "$cpus" upstream 1 "B C" "20 80" 3 "$out/control-upstream" ;;
    esac
  done
done
unset LOADGEN_ARGS

echo "=== idle $(date -Is)"
for cpus in 1 2; do
  "$here/run-config.sh" "$cpus" replicas 8 "A" "5" 1 "$out/idle-r8"
  EXTRA_ENV="-e TSS_REPLICA_TELEMETRY=mizu" "$here/run-config.sh" "$cpus" replicas 8 "A" "5" 1 "$out/idle-r8-mizu"
done

echo "=== failure $(date -Is)"
mkdir -p "$out/failure"
for variant in plain mizu; do
  for rep in 1 2 3; do
    docker rm -f tss-fail >/dev/null 2>&1 || true
    env_args=(); [ "$variant" = mizu ] && env_args=(-e TSS_REPLICA_TELEMETRY=mizu)
    docker run -d --name tss-fail --cpuset-cpus=4-5 "${env_args[@]}" "$IMAGE" replicas 2 >/dev/null
    sleep 8
    docker run --rm --network container:tss-fail --pid container:tss-fail --cpuset-cpus=16-17 \
      -v "$bench_dir:/bench" -w /bench node:24-slim node failure-check.mjs \
      --url http://127.0.0.1:3838/proxy/demo/ --mgmt http://127.0.0.1:3839 --victim demo-2 \
      --sessions 6 --watch 25 --op-timeout 30 --out "results/$(basename "$out")/failure/${variant}_r${rep}.json" \
      > "$out/failure/${variant}_r${rep}.txt" 2>&1 || true
    docker exec tss-fail cat /tmp/logs/server.log > "$out/failure/${variant}_r${rep}.log"
    docker rm -f tss-fail >/dev/null
  done
done
echo "=== done $(date -Is)"
