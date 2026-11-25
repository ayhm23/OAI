#!/usr/bin/env bash
# Multi-UE capacity/latency experiment. usage: experiment.sh <N UEs> [secs=10]
# Needs: core up, gNB up, UE 1..N registered (see README). Results: $LAB/run/tests/exp-<N>ue/
set -uo pipefail
. "$(dirname "$0")/env.sh"
N=${1:?usage: experiment.sh <N> [secs]}; T=${2:-10}
L="$KIT/lab.sh"; OUT="$LAB/run/tests/exp-${N}ue"; mkdir -p "$OUT"
EXT=$(dk compose -p "$PROJ" -f "$LAB/cn5g/docker-compose.yaml" ps -q oai-ext-dn 2>/dev/null | head -1)
[ -n "$EXT" ] || { echo "ext-dn container of project $PROJ not found" >&2; exit 1; }
# one iperf3 server per UE (a server handles one test at a time); ports 5201.. inside MY ext-dn
for i in $(seq 1 "$N"); do dk exec -d "$EXT" iperf3 -s -D -p $((5200 + i)) 2>/dev/null || true; done
sleep 1
for i in $(seq 1 "$N"); do
  o=$("$L" ue-ip "$i")
  grep -q "ue-embb.*10\.0\.0\." <<<"$o" && grep -q "ue-urllc.*10\.0\.2\." <<<"$o" \
    || { echo "UE $i is not registered with both slices, aborting" >&2; exit 1; }
done
sum() {  # sum of the Mbit/s of the receiver lines for files $@
  grep -h "receiver" "$@" 2>/dev/null | awk '{for(k=1;k<=NF;k++) if($k=="Mbits/sec") s+=$(k-1)} END{printf "%.1f", s}'
}
for sl in embb urllc; do
  echo "=== slice $sl"
  echo "-- 1. idle RTT, UE 1 alone"
  "$L" ping 1 $sl 20 > "$OUT/ping-$sl-alone.txt"; tail -2 "$OUT/ping-$sl-alone.txt" | grep rtt
  echo "-- 2. throughput, UE 1 alone (DL, UL)"
  for d in dl ul; do "$L" iperf 1 $sl $T $d 5201 > "$OUT/iperf-$sl-$d-alone.txt"; echo "$d: $(sum "$OUT/iperf-$sl-$d-alone.txt") Mbit/s"; done
  echo "-- 3. all $N UEs at once: RTT"
  for i in $(seq 1 "$N"); do "$L" ping "$i" $sl 20 > "$OUT/ping-$sl-all-ue$i.txt" & done; wait
  for i in $(seq 1 "$N"); do echo "UE$i $(grep rtt "$OUT/ping-$sl-all-ue$i.txt" | cut -d= -f2)"; done
  echo "-- 4. all $N UEs at once: throughput"
  for d in dl ul; do
    for i in $(seq 1 "$N"); do "$L" iperf "$i" $sl $T $d $((5200 + i)) > "$OUT/iperf-$sl-$d-all-ue$i.txt" & done; wait
    echo "$d per UE (Mbit/s): $(for i in $(seq 1 "$N"); do printf '%s ' "$(sum "$OUT/iperf-$sl-$d-all-ue$i.txt")"; done)"
    echo "$d aggregate: $(sum "$OUT"/iperf-$sl-$d-all-ue*.txt) Mbit/s"
  done
done 2>&1 | tee "$OUT/summary.txt"
