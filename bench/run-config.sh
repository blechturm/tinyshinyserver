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
# IDLE_SECONDS (default 10), SCHEDULER, EXTRA_ENV (extra "-e K=V" arguments for the server container),
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

# One benchmark at a time: two would share the server container's name and
# the machine's CPUs. A lock left by a killed run is taken over.
lock="${TMPDIR:-/tmp}/tss-bench.lock"
if ! mkdir "$lock" 2>/dev/null; then
  other=$(cat "$lock/pid" 2>/dev/null || echo "")
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    echo "Another benchmark (pid $other) is running; not starting" >&2
    exit 1
  fi
fi
echo $$ > "$lock/pid"

docker network inspect tssbench >/dev/null 2>&1 || docker network create tssbench >/dev/null
if ! docker ps --format '{{.Names}}' | grep -qx tss-load; then
  docker rm -f tss-load >/dev/null 2>&1 || true
  docker run -d --name tss-load --network tssbench --cpuset-cpus="$LOAD_CPUS" \
    -v "$bench_dir:/bench" -w /bench node:24-slim sleep infinity >/dev/null
fi
docker rm -f tss-server >/dev/null 2>&1 || true
docker run -d --name tss-server --network tssbench --cpuset-cpus="$cpuset" \
  ${EXTRA_ENV:-} ${SCHEDULER:+-e SCHEDULER=$SCHEDULER} "$IMAGE" "$mode" "$n" >/dev/null
trap 'docker rm -f tss-server >/dev/null 2>&1 || true; rm -rf "$lock"' EXIT

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

# Per-process CPU ticks and RSS, the host time they were taken (.t), and
# the container's cgroup (v1) memory: usage, peak since the container
# started, and its RSS and page cache (.mem)
snapshot() {
  docker exec tss-server /bench/procstat.sh > "$1"
  date +%s.%N > "$1.t"
  docker exec tss-server sh -c \
    'm=/sys/fs/cgroup/memory; echo current $(cat $m/memory.usage_in_bytes); echo peak $(cat $m/memory.max_usage_in_bytes); grep -E "^total_(rss|cache|shmem) " $m/memory.stat' \
    > "$1.mem" 2>/dev/null || true
}

# Idle consumption of the whole tree, before any load
snapshot "$out/raw/c${cpus}_${label}_idle.before"
sleep "${IDLE_SECONDS:-10}"
snapshot "$out/raw/c${cpus}_${label}_idle.after"
echo "ready_s $ready_s" > "$out/raw/c${cpus}_${label}_meta.txt"
docker exec tss-server cat /bench/VERSIONS >> "$out/raw/c${cpus}_${label}_meta.txt"

runs=()
for s in $scenarios; do for u in $users_list; do for r in $(seq 1 "$reps"); do runs+=("$s $u $r"); done; done; done
mapfile -t runs < <(printf '%s\n' "${runs[@]}" | shuf)
for run in "${runs[@]}"; do
  read -r s u r <<< "$run"
  id="c${cpus}_${label}_${s}_u${u}_r${r}"
  # The speed of the vCPUs this run gets, as a covariate: Hyper-V moves the
  # VM's vCPUs between performance and efficiency cores
  docker exec tss-server Rscript /bench/calibrate.R 2>/dev/null | grep "per ms" > "$out/raw/$id.calib" || true
  snapshot "$out/raw/$id.proc0"
  docker exec tss-load node loadgen.mjs --url "$url" --scenario "$s" --users "$u" \
    --duration "$DURATION" --warmup "$WARMUP" --seed "$r$u" ${LOADGEN_ARGS:-} \
    --out "$rel_out/raw/$id.csv" --summary "$rel_out/raw/$id.json" > /dev/null &
  loadgen=$!
  sleep $(( WARMUP + (DURATION - WARMUP) / 2 ))
  snapshot "$out/raw/$id.proc1"
  wait $loadgen
  snapshot "$out/raw/$id.proc2"
  echo "[$label c$cpus] $id done"
  sleep 3
done
