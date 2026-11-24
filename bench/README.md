# Benchmarks of the load-balancing spike

Everything needed to reproduce the measurements in
`docs/load-balancing-spike.md`: the benchmark apps, a Shiny load generator
that speaks the protocol, the Docker image, the run scripts and the
analysis. The raw results of the runs in the report are in `results/`, so
the analysis can also be repeated without running anything.

## Requirements

- Docker (tested with 29.6 on WSL2, cgroup v1; cgroup v2 hosts need the
  memory paths in `run-config.sh` adjusted).
- bash and git (on Windows: Git Bash).
- R with ggplot2, scales and jsonlite, for `analyze.R` only.
- At least 20 logical CPUs for the default pinning: the server container
  on CPUs 4–5 (`SERVER_CPU0`), the load generator on 16–19
  (`LOAD_CPUS`). Set both to fit your machine; keep them disjoint.

The load generator runs in a `node:24-slim` container; no Node.js
installation is needed on the host.

## Re-run the analysis only

```sh
Rscript bench/analyze.R /tmp/analysis bench/results/matrix
Rscript bench/analyze.R /tmp/followup bench/results/followup/data-memory \
  bench/results/followup/data-mori bench/results/followup/data-duckdb \
  bench/results/followup/async-sync bench/results/followup/async-async4 \
  bench/results/followup/async-async1
```

This recomputes `results/analysis/` and `results/followup-analysis/`
(per-run CSV, per-cell summaries, plots) from the raw files.

## Run the benchmarks

```sh
cd bench
./docker/build.sh                 # image tss-bench: upstream, the spike, the apps
# one configuration, e.g. 4 replicas on 1 vCPU, scenario B, 20 users, 2 repetitions:
./run-config.sh 1 replicas 4 "B" "20" 2 results/mine
# the matrix of the report (phase 1: B; 2t: A, C, D); about 4 hours in all
./run-all.sh results/mine "1 2t"
Rscript analyze.R results/mine-analysis results/mine
```

`build.sh` exports the committed spike (`HEAD`) and the upstream commit it
branched from with `git archive`, so uncommitted changes are not
benchmarked. Configurations (`MODE N`): `direct 1` (plain
`shiny::runApp()`), `upstream 1`, `spike 1`, `replicas N`.
Scenarios: A light, B 20% heavy CPU, C 20% blocking I/O, D CPU saturation
(see the report, section 4). Only one benchmark can run at a time.

Follow-ups and mizu, each in its own image built from the same Dockerfile:

```sh
IMAGE=tss-bench-follow ./docker/build.sh
./followup/smoke.sh                               # short check of every arm
./followup/run-followup.sh results/followup-mine  # about 80 minutes
IMAGE=tss-bench-mizu ./docker/build.sh
./mizu/run-mizu.sh results/mizu-mine              # prepared, not run for the report
```

## Correctness checks

Against a local server with a replica group of the benchmark app, for
example with this `config.json`:

```json
{ "apps": [{ "name": "demo", "path": "bench/app", "resident": true, "replicas": 4 }],
  "proxy_port": 3838, "management_port": 3839 }
```

```sh
R -e 'pkgload::load_all(); start_tss("config.json")' &   # from the repository root
node bench/affinity-check.mjs --url http://127.0.0.1:3838/proxy/demo/ --sessions 8
node bench/failure-check.mjs --url http://127.0.0.1:3838/proxy/demo/ --mgmt http://127.0.0.1:3839 --victim demo-1
NODE_PATH=<dir with playwright> node bench/browser-check.cjs http://127.0.0.1:3838/proxy/demo/ http://127.0.0.1:3839
```

These need Node.js 22 or later on the host; the browser check also needs
Playwright with Chromium.

## Files

| | |
|---|---|
| `app/`, `app-data/`, `app-async/` | benchmark apps: CPU, I/O, state, upload, download; shared data (memory, mori, DuckDB); `ExtendedTask` with mirai |
| `loadgen.mjs`, `shiny-client.mjs` | protocol-level load generator |
| `docker/` | image, server start script, process and memory snapshots, CPU calibration |
| `run-config.sh`, `run-all.sh` | one configuration; the matrix |
| `followup/`, `mizu/` | follow-up and mizu experiments |
| `analyze.R` | analysis and plots |
| `results/` | raw data, logs and analysis of the runs in the report |
