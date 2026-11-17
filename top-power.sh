#!/usr/bin/env bash
# Print the three apps using the most CPU over a short sample, as
# "name<TAB>cpu%" rows, highest first. Linux has no per-app watt meter, so CPU
# time is the stand-in. Reads only the user's own processes in /proc and
# groups them by command name (all "chromium" processes count as one).

set -u

sample=${1:-2}
[[ $sample =~ ^[1-9]$ ]] || sample=2
hz=$(getconf CLK_TCK 2>/dev/null || echo 100)

declare -A before names total

# Sets TICKS (user + system time) and NAME for one /proc/<pid> directory.
read_proc() {
  local dir=$1 line rest
  local -a f
  [[ -O $dir ]] || return 1
  IFS= read -r line <"$dir/stat" 2>/dev/null || return 1
  IFS= read -r NAME <"$dir/comm" 2>/dev/null || return 1
  rest=${line##*) }
  read -r -a f <<<"$rest"
  (( ${#f[@]} >= 13 )) || return 1
  TICKS=$(( f[11] + f[12] ))
}

start=$(date +%s%N)
for dir in /proc/[0-9]*; do
  read_proc "$dir" || continue
  before[${dir#/proc/}]=$TICKS
  names[${dir#/proc/}]=$NAME
done

sleep "$sample"
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
(( elapsed_ms > 0 )) || exit 0

for pid in "${!before[@]}"; do
  read_proc "/proc/$pid" || continue
  [[ $NAME == "${names[$pid]}" ]] || continue  # pid was reused
  delta=$(( TICKS - before[$pid] ))
  (( delta > 0 )) || continue
  case $NAME in top-power.sh|sleep) continue ;; esac  # this script and its sleep
  total[$NAME]=$(( ${total[$NAME]:-0} + delta ))
done

# CPU % in tenths: ticks / hz seconds of CPU over elapsed seconds of wall time.
for name in "${!total[@]}"; do
  tenths=$(( total[$name] * 1000000 / (hz * elapsed_ms) ))
  printf '%s\t%d.%d\n' "$name" $(( tenths / 10 )) $(( tenths % 10 ))
done | sort -t $'\t' -k2,2nr | head -n 3
