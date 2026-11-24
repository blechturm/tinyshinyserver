#!/usr/bin/env bash
# Smoke-test the follow-up image: the async app and each data mode serve a
# short load without errors. Exits non-zero on any failure.
set -euo pipefail
export MSYS_NO_PATHCONV=1
IMAGE=${IMAGE:-tss-bench-follow}
check() {
  local name=$1 scenario=$2; shift 2
  docker rm -f tss-smoke >/dev/null 2>&1 || true
  docker run -d --name tss-smoke --network tssbench --cpuset-cpus=20-21 "$@" "$IMAGE" replicas 2 >/dev/null
  for i in $(seq 1 120); do
    docker exec tss-load node -e 'Promise.all([1,2].map(i => fetch("http://tss-smoke:3838/proxy/demo-" + i + "/"))).then(r => process.exit(r.every(x => x.status === 200) ? 0 : 1), () => process.exit(1))' && break
    sleep 1
  done
  local summary
  summary=$(docker exec tss-load node loadgen.mjs --url http://tss-smoke:3838/proxy/demo/ --scenario "$scenario" --users 6 --duration 12 --warmup 2 --op-timeout 20)
  docker rm -f tss-smoke >/dev/null
  echo "$name: $summary" | cut -c1-400
  echo "$summary" | grep -q '"errors":0' && echo "$summary" | grep -q '"session_errors":0' && echo "$summary" | grep -qv '"ops":{}'
}
check async B -e BENCH_APP=/bench/app-async -e BENCH_DAEMONS=1
for data in memory mori duckdb; do
  check "data-$data" Q -e BENCH_APP=/bench/app-data -e BENCH_DATA_MODE=$data
done
echo "smoke tests passed"
