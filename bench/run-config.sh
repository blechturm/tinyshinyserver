#!/usr/bin/env bash
# Benchmark one server configuration under a set of workloads.
#
#   bench/run-config.sh CPUS MODE N "SCENARIOS" "USERS" REPS OUTDIR
#
#   CPUS       vCPUs given to the whole server container (1, 2, 4, ...)
#   MODE N     arguments of serve.sh: direct | upstream | spike | replicas N
#   SCENARIOS  e.g. "A B C D"; USERS e.g. "5 10 20 40 80"; REPS repetitions
#
# The server container is pinned with --cpuset-cpus, which confines its
# whole process tree, the proxy and every app process, to CPUS vCPUs. The
# load generator runs in its own container on other vCPUs. Runs are made in
# shuffled order. For each run the script stores the load generator's raw
# per-operation CSV and summary JSON, and per-process CPU ticks and RSS
# before, halfway through, and after the run.
#
# Environment: SERVER_CPU0 (first vCPU of the server, default 4), LOAD_CPUS
# (default 16-19), DURATION (s, default 32), WARMUP (s, default 8), IMAGE,
# SCHEDULER, EXTRA_ENV (extra "-e K=V" arguments for the server container),
# LOADGEN_ARGS (extra load generator arguments, e.g. "--session-ops 5").
set -euo pipefail
export MSYS_NO_PATHCONV=1
cpus=$1; mode=$2; n=$3; scenarios=$4; users_list=$5; reps=$6; out=$7
IMAGE=${IMAGE:-tss-bench}
SERVER_CPU0=${SERVER_CPU0:-4}
LOAD_CPUS=${LOAD_CPUS:-16-19}
DURATION=${DURATION:-32}
WARMUP=${WARMUP:-8}
here=$(cd "$(dirname "$0")" && pwd)
bench_dir=$(cygpath -m "$here" 2>/dev/null || echo "$here")
label=$mode; [ "$mode" = "replicas" ] && label="r$n"; [ "$mode" = "spike" ] && label="spike1"
[ -n "${SCHEDULER:-}" ] && label="${label}-${SCHEDULER}"
cpuset="$SERVER_CPU0-$((SERVER_CPU0 + cpus - 1))"
mkdir -p "$out/raw"
rel_out=$(realpath --relative-to="$here" "$out")

docker network inspect tssbench >/dev/null 2>&1 || docker network create tssbench >/dev/null
if ! docker ps --format '{{.Names}}' | grep -qx tss-load; then
  docker rm -f tss-load >/dev/null 2>&1 || true
  docker run -d --name tss-load --network tssbench --cpuset-cpus="$LOAD_CPUS" \
    -v "$bench_dir:/bench" -w /bench node:24-slim sleep infinity >/dev/null
fi
docker rm -f tss-server >/dev/null 2>&1 || true
docker run -d --name tss-server --network tssbench --cpuset-cpus="$cpuset" \
  ${EXTRA_ENV:-} ${SCHEDULER:+-e SCHEDULER=$SCHEDULER} "$IMAGE" "$mode" "$n" >/dev/null
trap 'docker rm -f tss-server >/dev/null 2>&1 || true' EXIT

url="http://tss-server:3838/proxy/demo/"
ready_paths="/proxy/demo/"
[ "$mode" = "direct" ] && url="http://tss-server:3838/" && ready_paths="/"
[ "$mode" = "replicas" ] && ready_paths=$(for i in $(seq 1 "$n"); do printf '/proxy/demo-%s/ ' "$i"; done)
started=$(date +%s.%N)
for attempt in $(seq 1 240); do
  if docker exec tss-load node -e '
    const paths = process.argv.slice(1);
    Promise.all(paths.map((p) => fetch("http://tss-server:3838" + p, { redirect: "manual" }).then((r) => r.status === 200 || r.status === 307)))
      .then((ok) => process.exit(ok.every(Boolean) ? 0 : 1), () => process.exit(1));' $ready_paths 2>/dev/null; then
    break
  fi
  sleep 0.5
done
ready_s=$(awk -v a="$(date +%s.%N)" -v b="$started" 'BEGIN { printf "%.1f", a - b }')
echo "[$label c$cpus] ready after ${ready_s}s"

# Idle consumption of the whole tree over 10 s, before any load
docker exec tss-server /bench/procstat.sh > "$out/raw/c${cpus}_${label}_idle.before"
sleep 10
docker exec tss-server /bench/procstat.sh > "$out/raw/c${cpus}_${label}_idle.after"
echo "ready_s $ready_s" > "$out/raw/c${cpus}_${label}_meta.txt"
docker exec tss-server cat /bench/VERSIONS >> "$out/raw/c${cpus}_${label}_meta.txt"

runs=()
for s in $scenarios; do for u in $users_list; do for r in $(seq 1 "$reps"); do runs+=("$s $u $r"); done; done; done
mapfile -t runs < <(printf '%s\n' "${runs[@]}" | shuf)
for run in "${runs[@]}"; do
  read -r s u r <<< "$run"
  id="c${cpus}_${label}_${s}_u${u}_r${r}"
  docker exec tss-server /bench/procstat.sh > "$out/raw/$id.proc0"
  docker exec tss-load node loadgen.mjs --url "$url" --scenario "$s" --users "$u" \
    --duration "$DURATION" --warmup "$WARMUP" --seed "$r$u" \
    --out "$rel_out/raw/$id.csv" --summary "$rel_out/raw/$id.json" > /dev/null &
  loadgen=$!
  sleep $(( WARMUP + (DURATION - WARMUP) / 2 ))
  docker exec tss-server /bench/procstat.sh > "$out/raw/$id.proc1"
  wait $loadgen
  docker exec tss-server /bench/procstat.sh > "$out/raw/$id.proc2"
  echo "[$label c$cpus] $id done"
  sleep 3
done
