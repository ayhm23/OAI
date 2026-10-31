# oai-lab-kit: every value that makes this lab mine. Source it: . ./env.sh
# Change values here only; all scripts derive names/addresses from these.

export KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# under sudo, $HOME is /root: resolve the invoking user's home instead
export LAB_USER="${SUDO_USER:-$(id -un)}"
export LAB="${LAB:-$(getent passwd "$LAB_USER" | cut -d: -f6)/oai-lab}"  # root of everything I create
export SUB=77                          # subnet octet: core 192.168.$SUB.128/26, UE links 10.$SUB.i.0/24
export RFPORT=4077                     # rfsimulator server port (upstream default 4043 left to others)
export CPUS=12-15,28-31                # 4 physical cores + SMT siblings (same CCD/L3), gNB/UE/build only here
export JOBS=8                          # max compile jobs

# Set explicitly (not derived from $USER: "oai" is too generic on this host)
export TAG=oailab77
export PROJ=$TAG-cn                    # docker compose project
export NETNAME=$TAG-net                # docker network name
export BRIDGE=br-$TAG                  # linux bridge name (<=15 chars)

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
export EXTDN_IP=192.168.$SUB.135

# Per-UE names (i = 1..4); all <= 15 chars
ue_ns()      { echo "$TAG-ue$1"; }          # netns
ue_veth_h()  { echo "v$TAG""h$1"; }         # host end, e.g. voailab77h1
ue_veth_n()  { echo "v$TAG""n$1"; }         # netns end
ue_host_ip() { echo "10.$SUB.$1.1"; }
ue_ns_ip()   { echo "10.$SUB.$1.2"; }
ue_imsi()    { printf '00101000000000%d' "$1"; }

# docker: use group membership directly if this shell has it, else via sg
dk() {
  if docker info >/dev/null 2>&1; then docker "$@"
  else sg docker -c "$(printf '%q ' docker "$@")"; fi
}

for _n in "$BRIDGE" "$(ue_veth_h 4)" "$(ue_veth_n 4)" "$(ue_ns 4)"; do
  [ ${#_n} -le 15 ] || echo "env.sh: WARNING name '$_n' is longer than 15 chars" >&2
done
unset _n
