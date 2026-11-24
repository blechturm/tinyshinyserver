#!/bin/sh
# Start one benchmark configuration in the container:
#   serve.sh direct        Shiny's own server, no proxy
#   serve.sh upstream      unmodified tinyshinyserver, one app process
#   serve.sh spike         modified tinyshinyserver, one app process (no replicas)
#   serve.sh replicas N    modified tinyshinyserver, a group of N replicas
#   [SCHEDULER=round_robin] chooses the group's scheduler
#   [BENCH_APP=/bench/app-data] serves another benchmark app; with
#   BENCH_DATA_MODE=mori, a data owner process shares the dataset first
set -e
mode="$1"; n="${2:-1}"
app_dir="${BENCH_APP:-/bench/app}"
if [ "${BENCH_DATA_MODE:-}" = "mori" ]; then
  rm -f /data/mori-name
  Rscript /bench/app-data/share-data.R /data /data/mori-name &
  while [ ! -s /data/mori-name ]; do sleep 0.2; done
fi
if [ "$mode" = "direct" ]; then
  exec Rscript -e "shiny::runApp('$app_dir', port = 3838, host = '0.0.0.0', launch.browser = FALSE)"
fi
lib=/opt/lib-spike
[ "$mode" = "upstream" ] && lib=/opt/lib-upstream
app="{\"name\": \"demo\", \"path\": \"$app_dir\", \"resident\": true}"
if [ "$mode" = "replicas" ]; then
  app="{\"name\": \"demo\", \"path\": \"$app_dir\", \"resident\": true, \"replicas\": $n, \"scheduler\": \"${SCHEDULER:-least_connections}\"}"
fi
cat > /tmp/config.json <<JSON
{
  "apps": [$app],
  "starting_port": 3001, "proxy_port": 3838, "proxy_host": "0.0.0.0",
  "management_port": 3839, "log_dir": "/tmp/logs",
  "idle_timeout_minutes": 0, "max_unanswered_mb": 0,
  "restart_delay": ${RESTART_DELAY:-5}, "health_check_interval": ${HEALTH_CHECK_INTERVAL:-10}
}
JSON
exec Rscript -e "library(tinyshinyserver, lib.loc = '$lib'); start_tss('/tmp/config.json')"
