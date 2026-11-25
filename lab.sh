#!/usr/bin/env bash
# oai-lab-kit runtime control. Touches only my objects: compose project $PROJ,
# tmux sessions/sockets $TAG-*, netns/veth named with $TAG, processes using $LAB/conf/.
# Usage: ./lab.sh <command> [args]   (./lab.sh help)
set -euo pipefail
. "$(dirname "$0")/env.sh"

compose() { dk compose -p "$PROJ" -f "$LAB/cn5g/docker-compose.yaml" "$@"; }

need_root() {
  [ "$(id -u)" = 0 ] && return
  echo "This step needs root. Run it in your own terminal:"
  echo "  sudo $KIT/lab.sh $*"
  exit 3
}
not_root() { [ "$(id -u)" != 0 ] || { echo "run this without sudo" >&2; exit 1; }; }

# My RAN processes: command line references $LAB/conf/ AND it's a softmodem.
ran_pids() {  # [pattern under $LAB/conf/]
  local p
  for p in $(pgrep -u "$LAB_USER" -f -- "$LAB/conf/${1:-}" || true); do
    case "$(cat /proc/"$p"/comm 2>/dev/null)" in nr-softmodem|nr-uesoftmo*) echo "$p" ;; esac
  done
}
stop_pids() {  # SIGINT, wait up to 10 s, then SIGKILL
  local pids="$*" n
  [ -n "$pids" ] || return 0
  kill -INT $pids 2>/dev/null || true
  for n in $(seq 20); do
    kill -0 $pids 2>/dev/null || return 0
    sleep 0.5
  done
  kill -KILL $pids 2>/dev/null || true
}

# ---------------------------------------------------------------- core network
cn_pull() {
  # Pull only images missing locally: the image cache is shared by all users,
  # and re-pulling an existing tag (e.g. :latest) would change it for them.
  local img
  for img in $(compose config --images | sort -u); do
    if dk image inspect "$img" >/dev/null 2>&1; then echo "cn-pull: $img present, not pulling"
    else echo "cn-pull: pulling $img"; dk pull -q "$img"; fi
  done
}

cn_up() {
  [ -f "$LAB/cn5g/docker-compose.yaml" ] || { echo "run ./setup.sh cn5g first" >&2; exit 1; }
  "$KIT/check_conflicts.sh" cn
  cn_pull
  mkdir -p "$LAB/run/cn"
  compose up -d --pull never --wait --wait-timeout 180
  slice_limit apply
  compose ps
}

# Session AMBR of slice 2 is signalled to the UE but not policed by the simple-switch UPF, so shape it
# with tc inside MY ext-dn container (non-3GPP, contained): DL = HTB class for dst $SLICE2_POOL on eth0
# egress, UL = ingress policer for src $SLICE2_POOL. Slice 1 traffic is untouched.
slice_limit() {  # slice-limit [apply|show|clear] [rate]
  local act=${1:-apply} rate=${2:-$SLICE2_RATE}
  case $act in
    show)  compose exec -T oai-ext-dn sh -c "tc -s class show dev eth0; tc -s filter show dev eth0 parent ffff:; tc filter show dev eth0 parent 1:" ;;
    clear) compose exec -T oai-ext-dn sh -c "tc qdisc del dev eth0 root 2>/dev/null; tc qdisc del dev eth0 ingress 2>/dev/null; true"; echo "slice-limit: cleared" ;;
    apply) compose exec -T oai-ext-dn sh -c "
      tc qdisc del dev eth0 root 2>/dev/null; tc qdisc del dev eth0 ingress 2>/dev/null
      tc qdisc add dev eth0 root handle 1: htb default 10 &&
      tc class add dev eth0 parent 1: classid 1:1 htb rate 10gbit &&
      tc class add dev eth0 parent 1:1 classid 1:10 htb rate 10gbit &&
      tc class add dev eth0 parent 1:1 classid 1:20 htb rate $rate ceil $rate burst 64k &&
      tc qdisc add dev eth0 parent 1:20 handle 20: fq_codel &&
      tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip dst $SLICE2_POOL flowid 1:20 &&
      tc qdisc add dev eth0 handle ffff: ingress &&
      tc filter add dev eth0 parent ffff: protocol ip prio 1 u32 match ip src $SLICE2_POOL police rate $rate burst 200k drop" \
      && echo "slice-limit: $SLICE2_POOL limited to $rate (DL shaped, UL policed) in ext-dn" ;;
    *) echo "usage: slice-limit [apply|show|clear] [rate]" >&2; return 1 ;;
  esac
}

cn_down() {
  tmux kill-session -t "$TAG-cnlogs" 2>/dev/null || true
  compose down
}

cn_logs() {
  mkdir -p "$LAB/run/cn"
  if [ "${1:-}" = "-f" ]; then
    tmux has-session -t "$TAG-cnlogs" 2>/dev/null && { echo "$TAG-cnlogs already running"; return; }
    tmux new-session -d -s "$TAG-cnlogs" \
      "bash -c '. $KIT/env.sh; dk compose -p $PROJ -f $LAB/cn5g/docker-compose.yaml logs -f --no-color 2>&1 | tee -a $LAB/run/cn/compose.log'"
    echo "following core logs in tmux $TAG-cnlogs -> $LAB/run/cn/compose.log"
  else
    compose logs --no-color --tail "${2:-200}" ${1:+"$1"}
  fi
}

# ------------------------------------------------------------------------- gNB
gnb() {
  not_root
  [ -f "$LAB/conf/gnb.conf" ] || "$KIT/setup.sh" conf
  [ -z "$(ran_pids gnb.conf)" ] || { echo "gNB already running: $(ran_pids gnb.conf)"; return; }
  ip -4 -o addr | grep -q " $GNB_IP/" || { echo "$GNB_IP absent: ./lab.sh cn-up first" >&2; exit 1; }
  "$KIT/check_conflicts.sh" gnb
  local d="$LAB/run/gnb"
  mkdir -p "$d"
  [ -f "$d/gnb.log" ] && mv "$d/gnb.log" "$d/gnb.prev.log"
  # cwd $d: nrL1/nrMAC/nrRRC stats files land here. No sudo: without CAP_SYS_NICE
  # OAI skips RT priority and per-thread pinning, so taskset's mask is never overridden.
  cat > "$d/run.sh" <<EOF
#!/usr/bin/env bash
cd "$d" || exit 1
taskset -c $CPUS "$BUILD/nr-softmodem" -O "$LAB/conf/gnb.conf" --gNBs.[0].min_rxtxtime 6 \\
  --rfsim --rfsimulator.[0].serveraddr server --rfsimulator.[0].serverport $RFPORT 2>&1 | tee "$d/gnb.log"
EOF
  chmod +x "$d/run.sh"
  tmux new-session -d -s "$TAG-gnb" "$d/run.sh"
  echo "gNB started in tmux $TAG-gnb, log $d/gnb.log"
}

gnb_stop() { stop_pids $(ran_pids gnb.conf); tmux kill-session -t "$TAG-gnb" 2>/dev/null || true; }

# -------------------------------------------------------------------------- UE
# Each UE lives in netns $TAG-ue<i>. Root is needed once (ue-ns) to create the
# netns + veth and start a tmux server *inside* it, running as $LAB_USER with only
# CAP_NET_ADMIN (to create the TUN interfaces and per-session ip rules). After
# that, everything runs unprivileged through that tmux server (socket $TAG-ue<i>).
ut() { local i=$1; shift; tmux -L "$TAG-ue$i" "$@"; }

n6_gro() {  # ROOT: enable NAPI on host-side veths of my N6 bridge so the UPF's XDP redirect can reach ext-dn
  need_root n6-gro
  local v
  for v in $(ip -o link show master "$BRIDGE_N6" | awk -F': ' '{print $2}' | cut -d@ -f1); do
    ethtool -K "$v" gro on >/dev/null && echo "gro on: $v (bridge $BRIDGE_N6)"
  done
}

ue_ns_up() {
  local i=${1:?usage: ue-ns <i>}
  need_root ue-ns "$i"
  local ns h n uhome
  ns=$(ue_ns "$i"); h=$(ue_veth_h "$i"); n=$(ue_veth_n "$i")
  uhome=$(getent passwd "$LAB_USER" | cut -d: -f6)
  "$KIT/check_conflicts.sh" ue "$i"
  ip netns list | grep -qw "^$ns" || ip netns add "$ns"
  if ! ip link show "$h" >/dev/null 2>&1; then
    ip link add "$h" type veth peer name "$n" netns "$ns"
    ip addr add "$(ue_host_ip "$i")/24" dev "$h"
    ip -n "$ns" addr add "$(ue_ns_ip "$i")/24" dev "$n"
  fi
  ip link set "$h" up
  ip -n "$ns" link set "$n" up
  ip -n "$ns" link set lo up
  if ! sudo -u "$LAB_USER" tmux -L "$TAG-ue$i" has-session 2>/dev/null; then
    ip netns exec "$ns" capsh --caps="cap_net_admin+eip cap_setpcap,cap_setuid,cap_setgid+ep" \
      --keep=1 --user="$LAB_USER" --addamb=cap_net_admin -- \
      -c "cd '$uhome'; HOME='$uhome' tmux -L '$TAG-ue$i' new-session -d -s '$TAG-ue$i'"
  fi
  echo "UE $i: netns $ns, $h $(ue_host_ip "$i")/24 <-> $n $(ue_ns_ip "$i")/24, tmux -L $TAG-ue$i"
}

ue_ns_down() {  # root: kill everything in my netns, then delete it (veth pair goes with it)
  need_root ue-ns-down "${1:-all}"
  local i ns
  for i in $( [ "${1:-all}" = all ] && echo 1 2 3 4 || echo "$1" ); do
    ns=$(ue_ns "$i")
    ip netns list | grep -qw "^$ns" || continue
    ip netns pids "$ns" | xargs -r kill 2>/dev/null || true
    sleep 1
    ip netns pids "$ns" | xargs -r kill -9 2>/dev/null || true
    ip netns del "$ns"
    echo "removed netns $ns"
  done
}

# run a command inside UE i's netns (via its tmux server) and print its output
in_ns() {
  local i=$1; shift
  ut "$i" has-session 2>/dev/null || { echo "netns tmux for UE $i missing: sudo $KIT/lab.sh ue-ns $i" >&2; exit 1; }
  local out="$LAB/run/ue$i/cmd.$$.out"
  mkdir -p "$LAB/run/ue$i"
  ut "$i" run-shell "$* > '$out' 2>&1; echo \"rc=\$?\" >> '$out'"
  cat "$out"; rm -f "$out"
}

ue() {
  local i=${1:?usage: ue <i>}
  not_root
  [ -f "$LAB/conf/ue$i.conf" ] || "$KIT/setup.sh" conf
  ut "$i" has-session 2>/dev/null || need_root ue-ns "$i"
  [ -z "$(ran_pids "ue$i.conf")" ] || { echo "UE $i already running"; return; }
  [ -n "$(ran_pids gnb.conf)" ] || { echo "gNB not running: ./lab.sh gnb first" >&2; exit 1; }
  local d="$LAB/run/ue$i"
  mkdir -p "$d"
  [ -f "$d/ue.log" ] && mv "$d/ue.log" "$d/ue.prev.log"
  cat > "$d/run.sh" <<EOF
#!/usr/bin/env bash
cd "$d" || exit 1
taskset -c $CPUS "$BUILD/nr-uesoftmodem" -O "$LAB/conf/ue$i.conf" \\
  -r 106 --numerology 1 --band 78 -C 3619200000 \\
  --rfsim --rfsimulator.[0].serveraddr $(ue_host_ip "$i") --rfsimulator.[0].serverport $RFPORT 2>&1 | tee "$d/ue.log"
EOF
  chmod +x "$d/run.sh"
  ut "$i" new-window -d -n ue "$d/run.sh"
  echo "UE $i started in netns $(ue_ns "$i") (tmux -L $TAG-ue$i), log $d/ue.log"
}

ue_stop() {
  local i=${1:?usage: ue-stop <i>}
  stop_pids $(ran_pids "ue$i.conf")
}

ue_ip() {
  local i
  for i in ${1:-1 2 3 4}; do
    ut "$i" has-session 2>/dev/null || continue
    echo "== UE $i ($(ue_ns "$i"))"
    in_ns "$i" "ip -br -4 addr; ip rule | grep -v -e 'lookup local' -e 'lookup main' -e 'lookup default'; true"
  done
}

slice_if() { case "$1" in embb|1) echo ue-embb ;; urllc|2) echo ue-urllc ;; *) echo "slice must be embb|urllc" >&2; exit 2 ;; esac; }

ping_() {  # ping <i> <embb|urllc> [count] [payload bytes, with DF set]
  local i=${1:?usage: ping <i> <embb|urllc> [count] [size]} ifc sz=""; ifc=$(slice_if "${2:?slice}")
  [ -n "${4:-}" ] && sz="-s $4 -M do"
  in_ns "$i" "ping -c ${3:-10} -i 0.2 $sz -I $ifc $EXTDN_IP"
}

iperf_() {  # iperf <i> <embb|urllc> [seconds] [dl|ul] -- bound to the slice IP; dl = -R (default)
  local i=${1:?usage: iperf <i> <embb|urllc> [seconds] [dl|ul]} ifc dir=${4:-dl} rev=-R
  ifc=$(slice_if "${2:?slice}")
  case $dir in dl) rev=-R ;; ul) rev= ;; *) echo "direction must be dl or ul" >&2; return 1 ;; esac
  in_ns "$i" "ip=\$(ip -4 -o addr show dev $ifc | awk '{print \$4}' | cut -d/ -f1); \
echo \"bind \$ip ($ifc) $dir\"; timeout $(( ${3:-10} + 15 )) iperf3 -c $EXTDN_IP -B \$ip $rev -t ${3:-10} -f m"
}

# ---------------------------------------------------------------------- status
status() {
  echo "== core ($PROJ)"; compose ps 2>/dev/null || true
  echo "== network"
  local nn
  for nn in "$NETNAME" "$NETNAME_N6"; do
    dk network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}}{{end}} bridge={{index .Options "com.docker.network.bridge.name"}}' "$nn" 2>/dev/null || echo "$nn: absent"
  done
  echo "== tmux"; tmux ls 2>/dev/null | grep "^$TAG-" || echo "no $TAG-* sessions (default socket)"
  local s
  for s in /tmp/tmux-"$(id -u "$LAB_USER")"/"$TAG"-ue*; do
    [ -S "$s" ] && tmux -S "$s" ls 2>/dev/null | sed "s#^#socket $(basename "$s"): #"
  done
  echo "== netns"; ip netns list 2>/dev/null | grep "^$TAG-" || echo "no $TAG-* netns"
  echo "== veth"; ip -br link show type veth 2>/dev/null | grep "v$TAG" || echo "no v$TAG* veth"
  echo "== RAN processes using $LAB/conf/"
  local p; for p in $(ran_pids); do ps -o pid=,psr=,pcpu=,etime=,args= -p "$p" | cut -c1-160; done
  [ -n "$(ran_pids)" ] || echo none
}

stop() {  # RAN only (UEs, then gNB); core keeps running
  local i
  for i in 1 2 3 4; do stop_pids $(ran_pids "ue$i.conf"); done
  gnb_stop
  echo "RAN stopped"
}

down() {  # everything of mine; netns removal needs root
  stop
  cn_down
  local s
  for s in /tmp/tmux-"$(id -u "$LAB_USER")"/"$TAG"-ue*; do
    [ -S "$s" ] || continue
    tmux -S "$s" kill-server 2>/dev/null || true
    tmux -S "$s" ls >/dev/null 2>&1 || rm -f "$s"   # stale socket of a dead server
  done
  tmux ls 2>/dev/null | grep "^$TAG-" | cut -d: -f1 | xargs -r -n1 tmux kill-session -t || true
  if ip netns list 2>/dev/null | grep -q "^$TAG-"; then
    if [ "$(id -u)" = 0 ]; then ue_ns_down all
    else echo "netns still present; remove with:  sudo $KIT/lab.sh ue-ns-down all"; fi
  fi
}

usage() {
  cat <<EOF
usage: $0 <command>
  cn-up | cn-down        start (conflict check, pull missing, wait healthy) / remove my core
  cn-logs [svc] [n]      last n lines (default 200) of core logs; cn-logs -f follows in tmux
  gnb | gnb-stop         start/stop the gNB (tmux $TAG-gnb, log \$LAB/run/gnb/gnb.log)
  slice-limit [apply|show|clear] [rate]  tc limit for slice 2 inside my ext-dn (default $SLICE2_RATE)
  n6-gro                 ROOT: GRO on my N6 bridge's veths (needed after every cn-up with the eBPF UPF)
  ue-ns <i>              ROOT: netns $TAG-ue<i> + veth + in-netns tmux server
  ue <i> | ue-stop <i>   start/stop UE i inside its netns (log \$LAB/run/ue<i>/ue.log)
  ue-ip [i]              interfaces and per-slice ip rules inside the UE netns
  ping <i> <embb|urllc> [n] [size]      ping ext-dn ($EXTDN_IP) through a slice
  iperf <i> <embb|urllc> [secs] [dl|ul]  iperf3 via ext-dn, bound to the slice IP (default dl)
  status                 what of mine is running
  stop                   stop UEs and gNB (core stays up)
  down                   stop everything of mine (netns removal: sudo ... ue-ns-down all)
  ue-ns-down [i|all]     ROOT: delete my UE netns (and their veth pairs)
EOF
}

cmd=${1:-help}; shift || true
case "$cmd" in
  cn-up)      cn_up ;;
  cn-down)    cn_down ;;
  cn-pull)    cn_pull ;;
  cn-logs)    cn_logs "$@" ;;
  gnb)        gnb ;;
  gnb-stop)   gnb_stop ;;
  ue-ns)      ue_ns_up "$@" ;;
  n6-gro)     n6_gro ;;
  slice-limit) slice_limit "$@" ;;
  ue-ns-down) ue_ns_down "$@" ;;
  ue)         ue "$@" ;;
  ue-stop)    ue_stop "$@" ;;
  ue-ip)      ue_ip "$@" ;;
  ping)       ping_ "$@" ;;
  iperf)      iperf_ "$@" ;;
  status)     status ;;
  stop)       stop ;;
  down)       down ;;
  *)          usage ;;
esac
