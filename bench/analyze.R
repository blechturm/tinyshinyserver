# Summarize benchmark results into tables and plots.
#
#   Rscript bench/analyze.R OUT_DIR RESULTS_DIR [RESULTS_DIR ...]
#
# Each RESULTS_DIR is an output directory of run-config.sh (with raw/); its
# name becomes the "experiment" column.
#
# Per run:
# - The measurement window starts at the warm-up, or 2 s after the last
#   session of the run's first wave has opened, whichever is later, and ends
#   at the run's duration. (With session churn, sessions keep opening by
#   design; the window then starts at the warm-up.) Operations sent in the
#   window count.
# - Failed operations (errors and timeouts) are counted as such, beside the
#   latencies of the others.
# - CPU use is the difference of per-process CPU ticks between the snapshots
#   before and after the run, divided by the host time between them.
#   Memory: the container's cgroup usage halfway through, its peak, and the
#   RSS of the proxy and app processes halfway through.
# Per configuration, repetitions are pooled: latency quantiles are taken over
# all operations of all repetitions, and the per-repetition values are kept
# for the spread.

suppressPackageStartupMessages(library(ggplot2))
`%||%` <- function(a, b) if (is.null(a) || length(a) == 0) b else a
args <- commandArgs(trailingOnly = TRUE)
out <- args[[1]]
dirs <- args[-1]
dir.create(file.path(out, "plots"), recursive = TRUE, showWarnings = FALSE)
CLK_TCK <- 100
# CPU seconds of each operation, and the mean think time, per scenario role;
# see loadgen.mjs. Used for the nominal offered load.
ROLE_CPU <- c(light = 0, stateful = 0, heavy = 0.5, io = 0, saturate = 0.25)
ROLE_THINK <- c(light = 0.5, stateful = 0.5, heavy = 2, io = 1, saturate = 0.25)

read_proc <- function(file) {
  if (!file.exists(file) || file.size(file) == 0) return(NULL)
  p <- utils::read.table(file, col.names = c("pid", "ppid", "ticks", "rss_kb", "role"))
  p[p$role %in% c("proxy", "app"), ]
}
snapshot_time <- function(file) {
  t <- paste0(file, ".t")
  if (file.exists(t)) as.numeric(readLines(t, warn = FALSE)[1]) else as.numeric(file.mtime(file))
}
read_mem <- function(file) {
  f <- paste0(file, ".mem")
  if (!file.exists(f) || file.size(f) == 0) return(c(current = NA, peak = NA, rss = NA))
  kv <- utils::read.table(f, col.names = c("key", "value"), fill = TRUE)
  get <- function(k) as.numeric(kv$value[kv$key == k][1] %||% NA) / 1024^2
  c(current = get("current"), peak = get("peak"), rss = get("total_rss"))
}
cpu_seconds <- function(before, after) {
  if (is.null(before) || is.null(after)) return(c(proxy = NA, app = NA))
  m <- merge(before, after, by = c("pid", "role"), suffixes = c(".0", ".1"))
  new <- after[!after$pid %in% before$pid, ]
  d <- rbind(data.frame(role = m$role, ticks = m$ticks.1 - m$ticks.0), data.frame(role = new$role, ticks = new$ticks))
  c(proxy = sum(d$ticks[d$role == "proxy"]) / CLK_TCK, app = sum(d$ticks[d$role == "app"]) / CLK_TCK)
}
parse_id <- function(id) {
  m <- regmatches(id, regexec("^c(\\d+)_(.+)_([A-Z])_u(\\d+)_r(\\d+)$", id))[[1]]
  data.frame(cpus = as.integer(m[2]), config = m[3], scenario = m[4], users = as.integer(m[5]), rep = as.integer(m[6]))
}

runs <- list()
rows <- list()
idle <- list()
for (dir in dirs) {
  experiment <- basename(normalizePath(dir))
  for (json in list.files(file.path(dir, "raw"), "\\.json$", full.names = TRUE)) {
    id <- sub("\\.json$", "", basename(json))
    key <- parse_id(id)
    s <- jsonlite::fromJSON(json, simplifyVector = FALSE)
    detail <- s$session_detail
    churn <- isTRUE((s$session_ops %||% 0) > 0)
    first_wave <- Filter(function(d) is.numeric(d$startup_ms) && (!churn || d$arrival_ms < 3000), detail)
    last_open <- max(c(0, vapply(first_wave, function(d) d$arrival_ms + d$startup_ms, numeric(1))))
    start_ms <- if (churn) s$warmup_s * 1000 else max(s$warmup_s * 1000, last_open + 2000)
    end_ms <- s$duration_s * 1000
    window <- (end_ms - start_ms) / 1000
    raw <- utils::read.csv(sub("\\.json$", ".csv", json), colClasses = c(error = "character", replica = "character", pid = "character"))
    raw$error[is.na(raw$error)] <- ""
    inside <- raw[raw$sent_ms >= start_ms & raw$sent_ms < end_ms, ]
    ok <- inside$error == ""

    base <- function(suffix) file.path(dir, "raw", paste0(id, suffix))
    p0 <- base(".proc0"); p2 <- base(".proc2")
    elapsed <- snapshot_time(p2) - snapshot_time(p0)
    cpu <- cpu_seconds(read_proc(p0), read_proc(p2))
    if (key$config == "direct") cpu <- c(proxy = 0, app = cpu[["proxy"]]) # the app process is runApp's
    mid <- read_proc(base(".proc1"))
    mem <- read_mem(base(".proc1"))
    peak <- read_mem(p2)[["peak"]]
    calib <- base(".calib")
    calib <- if (file.exists(calib) && file.size(calib) > 0) as.numeric(sub(".*per ms: (\\d+).*", "\\1", readLines(calib)[1])) else NA

    roles <- vapply(detail, function(d) d$role, character(1))
    replicas <- vapply(detail, function(d) d$replica, character(1))
    first <- if (churn) seq_along(detail) <= s$users else rep(TRUE, length(detail))
    heavy <- roles %in% c("heavy", "io", "saturate") & first
    heavy_max <- if (any(heavy)) max(table(replicas[heavy])) else 0
    demand <- sum(vapply(seq_len(s$users) - 1, function(i) {
      role <- roles[first][i + 1] %||% "light"
      ROLE_CPU[[role]] / (ROLE_THINK[[role]] + ROLE_CPU[[role]])
    }, numeric(1)))
    dist <- table(replicas[first & replicas != ""])

    runs[[length(runs) + 1]] <- cbind(key, experiment = experiment, window_s = window,
      ops_per_s = sum(ok) / window, error_rate = if (nrow(inside)) mean(!ok) else NA,
      session_errors = s$session_errors, sessions = s$sessions,
      startup_p50_ms = s$startup_ms$p50 %||% NA, startup_p95_ms = s$startup_ms$p95 %||% NA,
      proxy_cores = cpu[["proxy"]] / elapsed, app_cores = cpu[["app"]] / elapsed,
      rss_proxy_mb = if (is.null(mid)) NA else sum(mid$rss_kb[mid$role == "proxy"]) / 1024,
      rss_apps_mb = if (is.null(mid)) NA else sum(mid$rss_kb[mid$role == (if (key$config == "direct") "proxy" else "app")]) / 1024,
      cgroup_mb = mem[["current"]], cgroup_rss_mb = mem[["rss"]], cgroup_peak_mb = peak,
      calib_per_ms = calib, heavy_on_busiest = heavy_max, heavy_users = sum(heavy),
      demand_cores = demand, sessions_max_share = if (length(dist)) max(dist) / sum(dist) else NA)
    if (any(ok) || nrow(inside)) {
      rows[[length(rows) + 1]] <- data.frame(key, experiment = experiment, op = inside$op,
        latency_ms = inside$latency_ms, ok = ok, window_s = window)
    }
  }
  for (before in list.files(file.path(dir, "raw"), "_idle\\.before$", full.names = TRUE)) {
    m <- regmatches(basename(before), regexec("^c(\\d+)_(.+)_idle\\.before$", basename(before)))[[1]]
    after <- sub("before$", "after", before)
    seconds <- snapshot_time(after) - snapshot_time(before)
    cpu <- cpu_seconds(read_proc(before), read_proc(after))
    if (m[3] == "direct") cpu <- c(proxy = 0, app = cpu[["proxy"]])
    proc <- read_proc(after)
    idle[[length(idle) + 1]] <- data.frame(experiment = experiment, cpus = as.integer(m[2]), config = m[3],
      seconds = seconds, idle_proxy_pct = 100 * cpu[["proxy"]] / seconds, idle_apps_pct = 100 * cpu[["app"]] / seconds,
      rss_proxy_mb = sum(proc$rss_kb[proc$role == "proxy"]) / 1024,
      rss_apps_mb = sum(proc$rss_kb[proc$role == "app"]) / 1024,
      cgroup_mb = read_mem(after)[["current"]])
  }
}
runs <- do.call(rbind, runs)
rows <- do.call(rbind, rows)
idle <- do.call(rbind, idle)
utils::write.csv(runs, file.path(out, "runs.csv"), row.names = FALSE)
if (!is.null(idle)) utils::write.csv(idle, file.path(out, "idle.csv"), row.names = FALSE)

keys <- c("experiment", "cpus", "config", "scenario", "users")
# Latency per configuration and operation, pooled over repetitions
op_groups <- split(rows, rows[c(keys, "op")], drop = TRUE)
ops <- do.call(rbind, lapply(op_groups, function(g) {
  lat <- g$latency_ms[g$ok]
  per_rep <- vapply(split(g, g$rep), function(r) {
    l <- r$latency_ms[r$ok]
    if (length(l)) stats::quantile(l, 0.95, names = FALSE) else NA
  }, numeric(1))
  throughput <- vapply(split(g, g$rep), function(r) sum(r$ok) / r$window_s[1], numeric(1))
  cbind(g[1, keys], op = g$op[1], n = length(lat), reps = length(per_rep),
    errors = sum(!g$ok), error_rate = mean(!g$ok),
    mean = if (length(lat)) mean(lat) else NA,
    p50 = stats::quantile(lat, 0.5, names = FALSE) %||% NA,
    p95 = stats::quantile(lat, 0.95, names = FALSE) %||% NA,
    p99 = stats::quantile(lat, 0.99, names = FALSE) %||% NA,
    p99_is_tail = length(lat) >= 1000,
    p95_rep_min = min(per_rep, na.rm = TRUE), p95_rep_max = max(per_rep, na.rm = TRUE),
    over_100ms = mean(lat > 100), over_250ms = mean(lat > 250),
    throughput = stats::median(throughput), throughput_min = min(throughput), throughput_max = max(throughput))
}))
rownames(ops) <- NULL
utils::write.csv(ops, file.path(out, "ops_summary.csv"), row.names = FALSE)

run_groups <- split(runs, runs[keys], drop = TRUE)
summ <- do.call(rbind, lapply(run_groups, function(g) {
  row <- g[1, keys]
  for (v in c("ops_per_s", "error_rate", "startup_p50_ms", "startup_p95_ms", "proxy_cores", "app_cores",
              "rss_proxy_mb", "rss_apps_mb", "cgroup_mb", "cgroup_rss_mb", "cgroup_peak_mb", "calib_per_ms",
              "heavy_on_busiest", "demand_cores", "sessions_max_share", "window_s")) {
    row[[v]] <- stats::median(g[[v]], na.rm = TRUE)
    row[[paste0(v, "_min")]] <- suppressWarnings(min(g[[v]], na.rm = TRUE))
    row[[paste0(v, "_max")]] <- suppressWarnings(max(g[[v]], na.rm = TRUE))
  }
  row$reps <- nrow(g)
  row$regime <- if (row$demand_cores < 0.8 * row$cpus) "below capacity" else "overloaded"
  row
}))
rownames(summ) <- NULL
utils::write.csv(summ, file.path(out, "runs_summary.csv"), row.names = FALSE)
ops <- merge(ops, summ[c(keys, "regime", "demand_cores")], by = keys, all.x = TRUE)

# Plots ---------------------------------------------------------------------
config_levels <- c("direct", "upstream", "spike1", "r2", "r4", "r8")
fix_levels <- function(d) { d$config <- factor(d$config, levels = intersect(config_levels, unique(d$config))); d }
replicas_of <- function(config) ifelse(grepl("^r\\d", config), as.integer(sub("^r(\\d+).*", "\\1", config)), 1L)
palette <- c(direct = "#7f7f7f", upstream = "#1f77b4", spike1 = "#17becf", r2 = "#ff7f0e", r4 = "#d62728", r8 = "#9467bd")
theme_set(theme_minimal(base_size = 11) + theme(legend.position = "bottom", panel.grid.minor = element_blank()))
save <- function(plot, name, w = 9, h = 5) {
  tryCatch(ggsave(file.path(out, "plots", name), plot, width = w, height = h, dpi = 130, bg = "white"),
    error = function(e) message("Skipped ", name, ": ", conditionMessage(e)))
}
cpu_label <- function(x) paste(x, ifelse(x == "1", "vCPU", "vCPUs"))
caption <- "Line: pooled over repetitions; bars: range of per-repetition p95"

line_plot <- function(d, y, ylab, title, log = TRUE, range = c("p95_rep_min", "p95_rep_max")) {
  d <- fix_levels(d)
  p <- ggplot(d, aes(users, .data[[y]], colour = config)) +
    geom_line(linewidth = 0.8) + geom_point(size = 1.5) +
    facet_wrap(~cpus, labeller = as_labeller(cpu_label)) +
    scale_colour_manual(values = palette, name = NULL) +
    scale_x_continuous(trans = "log2", breaks = c(5, 10, 20, 40, 80)) +
    labs(x = "Concurrent users", y = ylab, title = title)
  if (!is.null(range)) p <- p + geom_errorbar(aes(ymin = .data[[range[1]]], ymax = .data[[range[2]]]), width = 0.05, alpha = 0.5) +
    labs(caption = caption)
  if (log) p <- p + scale_y_log10()
  p
}

m <- ops[ops$experiment == "matrix", ]
r <- summ[summ$experiment == "matrix", ]
if (nrow(m)) {
  save(line_plot(m[m$scenario == "B" & m$op == "fast", ], "p95", "p95 latency of lightweight operations (ms)",
    "Scenario B: lightweight interactions while 20% of users run 0.5 s CPU jobs"), "B_fast_p95_vs_users.png")
  save(line_plot(m[m$scenario == "B" & m$op == "fast", ], "over_250ms", "Share of lightweight operations over 250 ms",
    "Scenario B: how often a lightweight interaction is held up", log = FALSE, range = NULL) +
    scale_y_continuous(labels = scales::percent), "B_fast_over250_vs_users.png")
  save(line_plot(m[m$scenario == "B" & m$op == "cpu", ], "p50", "p50 latency of CPU jobs (ms)",
    "Scenario B: latency of the 0.5 s CPU jobs themselves", range = NULL), "B_cpu_p50_vs_users.png")
  save(line_plot(m[m$scenario == "A" & m$op == "fast", ], "p95", "p95 latency (ms)",
    "Scenario A: lightweight interactions only (proxy and scheduling overhead)"), "A_fast_p95_vs_users.png")
  save(line_plot(m[m$scenario == "A" & m$op == "fast", ], "p50", "p50 latency (ms)",
    "Scenario A: median latency (proxy and scheduling overhead)", range = NULL), "A_fast_p50_vs_users.png")
  save(line_plot(m[m$scenario == "C" & m$op == "fast", ], "p95", "p95 latency of lightweight operations (ms)",
    "Scenario C: lightweight interactions while 20% of users block 0.5 s in Sys.sleep()"), "C_fast_p95_vs_users.png")
  save(line_plot(m[m$scenario == "C" & m$op == "io", ], "throughput", "Completed blocking operations per second",
    "Scenario C: throughput of blocking operations", log = FALSE, range = c("throughput_min", "throughput_max")),
    "C_io_throughput_vs_users.png")
  save(line_plot(m[m$scenario == "D" & m$op == "cpu", ], "throughput", "Completed CPU jobs per second",
    "Scenario D: CPU saturation, throughput of 0.25 s jobs", log = FALSE, range = c("throughput_min", "throughput_max")),
    "D_cpu_throughput_vs_users.png")
  save(line_plot(r[r$scenario == "B", ], "ops_per_s", "Completed operations per second",
    "Scenario B: aggregate throughput", log = FALSE, range = c("ops_per_s_min", "ops_per_s_max")),
    "B_throughput_vs_users.png")

  vs <- m[m$config != "direct" & m$users %in% c(20, 40, 80) &
    ((m$scenario %in% c("B", "C") & m$op == "fast") | (m$scenario == "D" & m$op == "cpu")), ]
  vs$replicas <- replicas_of(as.character(vs$config))
  vs$series <- paste(vs$users, "users")
  p <- ggplot(vs[vs$config != "upstream", ], aes(replicas, p95, colour = series)) +
    geom_hline(data = vs[vs$config == "upstream", ], aes(yintercept = p95, colour = series), linetype = "dashed") +
    geom_errorbar(aes(ymin = p95_rep_min, ymax = p95_rep_max), width = 0.1, alpha = 0.6) +
    geom_line() + geom_point() +
    facet_grid(paste("Scenario", scenario) ~ cpus, scales = "free_y", labeller = labeller(cpus = cpu_label)) +
    scale_x_continuous(trans = "log2", breaks = c(1, 2, 4, 8)) + scale_y_log10() +
    labs(x = "Replicas (1 = modified server, no replicas)", y = "p95 latency (ms)", colour = NULL,
      title = "Latency against replica count",
      subtitle = "B, C: lightweight operations; D: CPU jobs. Dashed: upstream. Bars: range over repetitions")
  save(p, "latency_vs_replicas.png", 9, 8)

  mem <- r[r$config != "direct" & r$scenario == "B" & r$users == 40, ]
  mem$replicas <- replicas_of(as.character(mem$config))
  memlong <- rbind(
    data.frame(cpus = mem$cpus, config = mem$config, replicas = mem$replicas, role = "proxy (RSS)", mb = mem$rss_proxy_mb),
    data.frame(cpus = mem$cpus, config = mem$config, replicas = mem$replicas, role = "app processes (RSS)", mb = mem$rss_apps_mb))
  p <- ggplot(memlong[memlong$config != "upstream", ], aes(factor(replicas), mb, fill = role)) +
    geom_col() +
    geom_point(data = mem[mem$config != "upstream", ], aes(factor(replicas), cgroup_rss_mb), inherit.aes = FALSE, shape = 4, size = 3) +
    facet_wrap(~cpus, labeller = as_labeller(cpu_label)) +
    labs(x = "Replicas (1 = no replicas)", y = "Memory (MB)", fill = NULL,
      title = "Memory against replica count",
      subtitle = "Halfway through scenario B with 40 users. Bars: summed RSS; x: container cgroup RSS (shared pages once)")
  save(p, "memory_vs_replicas.png")

  cmp <- m[m$scenario %in% c("B", "C", "D") & m$users == 40 & m$config %in% c("upstream", "r2", "r4", "r8") &
    ((m$scenario %in% c("B", "C") & m$op == "fast") | (m$scenario == "D" & m$op == "cpu")), ]
  cmp <- fix_levels(cmp)
  p <- ggplot(cmp, aes(factor(cpus), p95, fill = config)) +
    geom_col(position = position_dodge(0.85), width = 0.8) +
    geom_errorbar(aes(ymin = p95_rep_min, ymax = p95_rep_max), position = position_dodge(0.85), width = 0.2) +
    facet_wrap(~ paste("Scenario", scenario), scales = "free_y") + scale_fill_manual(values = palette) +
    scale_y_log10() + labs(x = "vCPUs", y = "p95 latency (ms)", fill = NULL,
      title = "Single-vCPU against multi-vCPU, 40 users", subtitle = "B, C: lightweight operations; D: CPU jobs")
  save(p, "vcpu_comparison.png")
}
cat("Wrote", nrow(runs), "runs to", out, "\n")
