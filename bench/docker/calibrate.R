# How many loop iterations of the benchmark app's burn() take 1 ms on one
# core of this machine. Run in the benchmark container on one CPU.
source_lines <- readLines("/bench/app/app.R")
start <- grep("^burn <- ", source_lines)
end <- start + grep("^})", source_lines[start:length(source_lines)])[1] - 1
ITERATIONS_PER_UNIT <- 1e5
eval(parse(text = source_lines[start:end]))
burn(10)
times <- replicate(7, system.time(burn(20))[["elapsed"]])
per_ms <- 1e5 * 20 / (median(times) * 1000)
cat(sprintf("iterations per ms: %.0f (median of %d runs; spread %.3f-%.3f s for 2e6)\n",
  per_ms, length(times), min(times), max(times)))
