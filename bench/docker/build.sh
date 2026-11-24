#!/usr/bin/env bash
# Build the benchmark image from committed sources:
#   bench/docker/build.sh [SPIKE_REF] [UPSTREAM_REF]
# SPIKE_REF defaults to HEAD; UPSTREAM_REF to the upstream commit the spike
# branched from. Both are exported with `git archive`, so uncommitted changes
# are not benchmarked.
set -euo pipefail
repo=$(git rev-parse --show-toplevel)
spike_ref=${1:-HEAD}
upstream_ref=${2:-$(git -C "$repo" merge-base HEAD origin/main)}
ctx=$(mktemp -d)
trap 'rm -rf "$ctx"' EXIT
mkdir -p "$ctx/src/upstream" "$ctx/src/spike" "$ctx/docker"
git -C "$repo" archive "$upstream_ref" | tar -x -C "$ctx/src/upstream"
git -C "$repo" archive "$spike_ref" | tar -x -C "$ctx/src/spike"
cp -r "$repo/bench/app" "$ctx/app"
cp -r "$repo/bench/mizu" "$ctx/mizu"
cp -r "$repo/bench/app-data" "$ctx/app-data"
cp -r "$repo/bench/app-async" "$ctx/app-async"
cp "$repo"/bench/docker/{Dockerfile,serve.sh,procstat.sh,calibrate.R} "$ctx/docker/"
echo "upstream $(git -C "$repo" rev-parse "$upstream_ref")" > "$ctx/docker/VERSIONS"
echo "spike $(git -C "$repo" rev-parse "$spike_ref")" >> "$ctx/docker/VERSIONS"
docker build -t "${IMAGE:-tss-bench}" -f "$ctx/docker/Dockerfile" "$ctx"
cat "$ctx/docker/VERSIONS"
