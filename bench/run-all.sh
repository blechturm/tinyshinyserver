#!/usr/bin/env bash
# The experimental matrix of the spike, in phases of decreasing priority.
#   bench/run-all.sh OUTDIR [PHASES]      e.g. bench/run-all.sh results/matrix "1 2 3 4"
# Server configurations within a phase run in shuffled order, so that drift
# in the machine's speed does not favour one of them.
set -euo pipefail
out=$1; phases=${2:-"1 2 3 4"}
here=$(cd "$(dirname "$0")" && pwd)
configs_all=("direct 1" "upstream 1" "spike 1" "replicas 2" "replicas 4" "replicas 8")
configs_tss=("upstream 1" "spike 1" "replicas 2" "replicas 4" "replicas 8")
run_phase() {
  local cpus_list=$1 scenarios=$2 users=$3 reps=$4; shift 4
  local jobs=()
  for c in $cpus_list; do for cfg in "$@"; do jobs+=("$c $cfg"); done; done
  mapfile -t jobs < <(printf '%s\n' "${jobs[@]}" | shuf)
  for job in "${jobs[@]}"; do
    read -r c mode n <<< "$job"
    "$here/run-config.sh" "$c" "$mode" "$n" "$scenarios" "$users" "$reps" "$out"
  done
}
for phase in $phases; do
  echo "=== phase $phase $(date -Is)"
  case $phase in
    # Head-of-line blocking (B) on 1 and 2 vCPUs, all user counts, all baselines
    1) run_phase "1 2" "B" "5 10 20 40 80" 3 "${configs_all[@]}" ;;
    # Overhead (A) with Shiny's own server as a baseline; blocking I/O (C)
    # and saturation (D) on the servers only; 1 and 2 vCPUs
    2) run_phase "1 2" "A" "5 20 80" 2 "${configs_all[@]}"
       run_phase "1 2" "C D" "5 20 80" 2 "${configs_tss[@]}" ;;
    # 4 vCPUs: heterogeneous and saturating CPU load
    3) run_phase "4" "B D" "10 40 80" 2 "${configs_tss[@]}" ;;
    # The scheduler comparison needs session churn; see mizu/run-mizu.sh
    4) ;;
    # Phase 2, trimmed after scenario B showed the modified server without
    # replicas to match upstream: A with all baselines, C and D without it
    2t) run_phase "1 2" "A" "5 20 80" 2 "direct 1" "upstream 1" "spike 1" "replicas 4" "replicas 8"
        run_phase "1 2" "C D" "5 20 80" 2 "upstream 1" "replicas 2" "replicas 4" "replicas 8" ;;
  esac
done
echo "=== done $(date -Is)"
