#!/usr/bin/env bash
# oai-lab-kit: read-only check that what I'm about to create doesn't clash with
# anything else on this shared host. Exit 0 = no conflict.
# Usage: ./check_conflicts.sh cn | gnb | ue <i> | all
set -uo pipefail
. "$(dirname "$0")/env.sh"

fail=0
bad()  { echo "CONFLICT: $*"; fail=1; }
ok()   { echo "ok:       $*"; }
info() { echo "info:     $*"; }

# prints the entries of stdin ("label cidr" lines) whose cidr overlaps $1
overlapping() {
  python3 -I -c '
import ipaddress, sys
t = ipaddress.ip_network(sys.argv[1], strict=False)
for line in sys.stdin:
    p = line.split()
    if len(p) >= 2:
        try:
            n = ipaddress.ip_network(p[-1], strict=False)
        except ValueError:
            continue
        if n.prefixlen and n.overlaps(t):
            print(line.strip())' "$1"
}

# kernel addresses/routes overlapping $1, ignoring device $2 (which is mine)
kernel_overlaps() {
  { ip -4 -o addr | awk '{print "addr dev=" $2, $4}'
    ip -4 route | awk '$1!="default"{d="?"; for(i=1;i<NF;i++) if($i=="dev") d=$(i+1); print "route dev=" d, $1}'
  } | overlapping "$1" | grep -v " dev=$2 " || true
}

# processes listening on a port; prints "mine" if owned by my RAN, else the line
port_users() {  # $1 = proto flag (t|u), $2 = port
  ss -Hln"$1"p "( sport = :$2 )" 2>/dev/null
}
is_my_pid() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q "$LAB/conf/"; }

check_cn() {
  echo "== core: network $NETNAME, bridge $BRIDGE, subnet $CN_SUBNET, project $PROJ"
  local line name subnets proj found=0
  while IFS='|' read -r name subnets proj; do
    if [ "$name" = "$NETNAME" ]; then
      found=1
      [ "$proj" = "$PROJ" ] && ok "docker network $NETNAME exists and belongs to $PROJ" \
                            || bad "docker network $NETNAME exists, owned by project '$proj'"
      continue
    fi
    for s in $subnets; do
      [ -n "$(echo "x $s" | overlapping "$CN_SUBNET")" ] && bad "docker network '$name' ($proj) uses $s"
    done
  done < <(dk network inspect -f '{{.Name}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}|{{index .Labels "com.docker.compose.project"}}' \
             $(dk network ls -q))
  [ $found = 0 ] && ok "no docker network named $NETNAME yet"
  while read -r line; do bad "kernel: $line overlaps $CN_SUBNET"; done < <(kernel_overlaps "$CN_SUBNET" "$BRIDGE")
  if ip link show "$BRIDGE" >/dev/null 2>&1; then
    [ $found = 1 ] && ok "bridge $BRIDGE exists (mine, from $NETNAME)" \
                   || bad "interface $BRIDGE exists but no docker network $NETNAME: not mine?"
  else ok "no interface named $BRIDGE yet"; fi
  local n; n=$(dk ps -aq --filter "label=com.docker.compose.project=$PROJ" | wc -l)
  info "$n container(s) in project $PROJ"
}

check_gnb() {
  echo "== gNB: rfsim TCP :$RFPORT, GTP-U $GNB_IP:2152/udp"
  local l pid
  l=$(port_users t "$RFPORT")
  if [ -z "$l" ]; then ok "TCP port $RFPORT free"
  else
    pid=$(echo "$l" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    if [ -n "$pid" ] && is_my_pid "$pid"; then ok "TCP $RFPORT held by my gNB (pid $pid)"
    else bad "TCP port $RFPORT in use: $l"; fi
  fi
  l=$(ss -Hlnup 2>/dev/null | awk '$4 ~ /:2152$/')
  while read -r x; do
    [ -z "$x" ] && continue
    pid=$(echo "$x" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
    if [ -n "$pid" ] && is_my_pid "$pid"; then ok "UDP 2152 held by my gNB (pid $pid)"
    elif echo "$x" | grep -qE "(0\.0\.0\.0|\*|$GNB_IP):2152"; then bad "UDP 2152 bound by someone else: $x"
    else info "UDP 2152 bound on another address (no clash with $GNB_IP): $x"; fi
  done <<< "$l"
  [ -z "$l" ] && ok "UDP 2152 free on host"
  ip -4 -o addr | grep -q " $GNB_IP/" && ok "$GNB_IP present (bridge $BRIDGE up)" \
                                     || info "$GNB_IP not present yet: core network must be up first"
}

check_ue() {
  local i=$1 ns h n net
  ns=$(ue_ns "$i"); h=$(ue_veth_h "$i"); n=$(ue_veth_n "$i"); net="10.$SUB.$i.0/24"
  echo "== UE $i: netns $ns, veth $h<->$n, link $net"
  ip netns list 2>/dev/null | grep -qw "^$ns" && info "netns $ns exists (my name)" || ok "netns $ns free"
  if ip link show "$h" >/dev/null 2>&1; then info "veth $h exists (my name)"; else ok "veth $h free"; fi
  ip link show "$n" >/dev/null 2>&1 && bad "$n exists in the host namespace (should be inside $ns)"
  while read -r line; do bad "kernel: $line overlaps $net"; done < <(kernel_overlaps "$net" "$h")
}

case "${1:-}" in
  cn)  check_cn ;;
  gnb) check_gnb ;;
  ue)  [ -n "${2:-}" ] || { echo "usage: $0 ue <i>" >&2; exit 2; }; check_ue "$2" ;;
  all) check_cn; check_gnb; for i in 1 2 3 4; do check_ue "$i"; done ;;
  *)   echo "usage: $0 cn | gnb | ue <i> | all" >&2; exit 2 ;;
esac
[ $fail = 0 ] && echo "RESULT: no conflicts" || echo "RESULT: CONFLICTS FOUND, do not proceed"
exit $fail
