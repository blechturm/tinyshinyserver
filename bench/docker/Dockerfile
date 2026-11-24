# Benchmark image: R with the unmodified upstream package and the spike
# installed side by side, so that every configuration runs on identical
# software. Built by bench/docker/build.sh, which places both sources in
# the build context.
FROM rocker/r-ver:4.6.1

# No hidden threads: the benchmark app does no BLAS work, but pin anyway
ENV OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1

RUN install2.r --error --skipinstalled \
      shiny httpuv websocket logger callr ps jsonlite later curl promises glue rmarkdown quarto \
  && rm -rf /tmp/downloaded_packages

# mizu, pinned to the tested version, for the optional telemetry experiment
RUN Rscript -e 'install.packages("https://cloud.r-project.org/src/contrib/mizu_0.1.1.tar.gz", repos = NULL, type = "source")'   && Rscript -e 'stopifnot(packageVersion("mizu") == "0.1.1")'

# The follow-up experiments: shared data (mori, DuckDB) and async offloading
# (mirai). DuckDB from Posit Package Manager's binaries; mori and mirai, small
# C packages, from CRAN.
RUN install2.r --error --skipinstalled DBI duckdb   && Rscript -e 'install.packages(c("mori", "mirai", "nanonext"), repos = "https://cloud.r-project.org")'   && rm -rf /tmp/downloaded_packages

COPY src/upstream /src/upstream
RUN mkdir -p /opt/lib-upstream && R CMD INSTALL --no-docs --library=/opt/lib-upstream /src/upstream

COPY src/spike /src/spike
RUN mkdir -p /opt/lib-spike && R CMD INSTALL --no-docs --library=/opt/lib-spike /src/spike

COPY app /bench/app
COPY app-data /bench/app-data
COPY app-async /bench/app-async
COPY mizu /bench/mizu
# The shared-data benchmark's dataset: about 270 MB in memory
RUN Rscript /bench/app-data/make-data.R /data 1e7
COPY docker/serve.sh docker/procstat.sh docker/calibrate.R docker/VERSIONS /bench/
RUN chmod +x /bench/*.sh   && Rscript -e 'for (p in c("mizu", "mori", "mirai", "nanonext", "duckdb", "shiny")) cat(p, format(packageVersion(p)), "\n")' >> /bench/VERSIONS
EXPOSE 3838 3839
ENTRYPOINT ["/bench/serve.sh"]
