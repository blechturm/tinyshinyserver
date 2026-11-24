# The data owner for BENCH_DATA_MODE=mori: reads the dataset once, shares it
# with mori, writes the region's name for the app processes to map, and stays
# alive, since processes can map a region only while its owner holds it.
# Replicas restart independently of each other, so no replica can own it.
# In a production version the tinyshinyserver process itself would be the
# owner; a separate process keeps this experiment from changing the server.
#
#   Rscript share-data.R DIR NAME_FILE

args <- commandArgs(trailingOnly = TRUE)
data <- readRDS(file.path(args[[1]], "data.rds"))
# Numeric columns are mapped without copying; character columns would be
# materialised in every process that reads them
shared <- mori::share(data)
rm(data)
invisible(gc())
writeLines(mori::shared_name(shared), args[[2]])
message("shared as ", mori::shared_name(shared))
repeat Sys.sleep(3600)
