# oai-lab-kit: every value that makes this lab mine. Source it: . ./env.sh
# Change values here only; all scripts derive names/addresses from these.

export KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# under sudo, $HOME is /root: resolve the invoking user's home instead
export LAB_USER="${SUDO_USER:-$(id -un)}"
export LAB="${LAB:-$(getent passwd "$LAB_USER" | cut -d: -f6)/oai-lab}"  # root of everything I create
export SUB=77                          # subnet octet: core 192.168.$SUB.128/26, UE links 10.$SUB.i.0/24
export RFPORT=4077                     # rfsimulator server port (upstream default 4043 left to others)
export CPUS=10-15,26-31                # 6 physical cores + SMT siblings (same CCD/L3), gNB/UE/build only here
export JOBS=8                          # max compile jobs
export MAX_UE=10                       # UE slots (netns/veth/conf/subscribers) the kit knows about

# Set explicitly (not derived from $USER: "oai" is too generic on this host)
export TAG=oailab77
export PROJ=$TAG-cn                    # docker compose project
export NETNAME=$TAG-net                # docker network name
export BRIDGE=br-$TAG                  # linux bridge name (<=15 chars)
export NETNAME_N6=$TAG-n6              # N6 docker network (UPF eth1 <-> ext-dn), needed by the eBPF UPF
export BRIDGE_N6=br-${TAG}n6           # its bridge (<=15 chars)

# Source tree
export REPO_URL=https://github.com/duranta-project/openairinterface5g.git
export BRANCH=develop
export SRC=$LAB/src/openairinterface5g
export BUILD=$SRC/cmake_targets/ran_build/build
# CMake's CPM downloads default to ~/.cache/cpm; keep them under $LAB instead
export CPM_SOURCE_CACHE=$LAB/src/cpm-cache

# Core network addressing (tutorial layout shifted from 192.168.70.x)
export CN_SUBNET=192.168.$SUB.128/26
export GNB_IP=192.168.$SUB.129         # host side of $BRIDGE; gNB NG/NGU
export AMF_IP=192.168.$SUB.132
export CN_SUBNET_N6=192.168.$SUB.192/26  # next /26 after the core subnet
export UPF_N6_IP=192.168.$SUB.194
export SLICE2_POOL=10.0.2.0/24         # UE pool of slice 2 (urllc), see patch_cn5g_slices.py
export SLICE2_RATE=50mbit              # session AMBR of slice 2, enforced with tc in ext-dn (UPF does not police)
export EXTDN_IP=192.168.$SUB.195       # ext-dn lives on the N6 network only

# Per-UE names (i = 1..$MAX_UE); all <= 15 chars
ue_ns()      { echo "$TAG-ue$1"; }          # netns
ue_veth_h()  { echo "v$TAG""h$1"; }         # host end, e.g. voailab77h1
ue_veth_n()  { echo "v$TAG""n$1"; }         # netns end
ue_host_ip() { echo "10.$SUB.$1.1"; }
ue_ns_ip()   { echo "10.$SUB.$1.2"; }
ue_imsi()    { printf '00101%010d' "$1"; }

# docker: use group membership directly if this shell has it, else via sg
dk() {
  if docker info >/dev/null 2>&1; then docker "$@"
  else sg docker -c "$(printf '%q ' docker "$@")"; fi
}

for _n in "$BRIDGE" "$(ue_veth_h $MAX_UE)" "$(ue_veth_n $MAX_UE)" "$(ue_ns $MAX_UE)"; do
  [ ${#_n} -le 15 ] || echo "env.sh: WARNING name '$_n' is longer than 15 chars" >&2
done
unset _n
