#!/bin/sh
# One line per process of the container: pid, ppid, CPU ticks (user +
# system), RSS in kB, and role (proxy: the server's own R session; app: an
# R process of an app; other). Ticks are divided by `getconf CLK_TCK`.
for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  [ -r "$d/stat" ] || continue
  stat=$(cat "$d/stat" 2>/dev/null) || continue
  rest=${stat##*) }
  set -- $rest
  ppid=$2; ticks=$(( ${12} + ${13} )); rss=$(( ${22} * 4 ))
  cmd=$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null | cut -c1-200)
  case "$cmd" in
    *start_tss*|*runApp*) role=proxy ;;
    *R*callr*|*/R\ *|*exec/R*) role=app ;;
    *) role=other ;;
  esac
  echo "$pid $ppid $ticks $rss $role"
done
