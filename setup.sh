#!/usr/bin/env bash
# oai-lab-kit setup: create $LAB layout, clone OAI, build gNB + nrUE (RF-sim).
# Usage: ./setup.sh layout | clone | simde | build | cn5g | conf | snapshot | all
# The build runs in tmux session $TAG-build; output goes to $LAB/logs/build.log.
set -euo pipefail
. "$(dirname "$0")/env.sh"

layout() {
  mkdir -p "$LAB"/{src,cn5g,conf,run,logs}
  echo "layout: $LAB/{src,cn5g,conf,run,logs}"
}

clone() {
  layout
  if [ -d "$SRC/.git" ]; then
    echo "clone: $SRC exists, fetching $BRANCH"
    git -C "$SRC" fetch origin "$BRANCH"
    git -C "$SRC" checkout "$BRANCH"
    git -C "$SRC" merge --ff-only "origin/$BRANCH"
  else
    git clone --filter=blob:none --branch "$BRANCH" "$REPO_URL" "$SRC"
  fi
  local h; h=$(git -C "$SRC" rev-parse HEAD)
  echo "$h  $(git -C "$SRC" log -1 --format='%cd %s' --date=short)" > "$LAB/COMMIT"
  echo "clone: $BRANCH at $(cat "$LAB/COMMIT")"
}

# Pre-fetch CPM.cmake with curl: CMake's file(DOWNLOAD) has no connect timeout and
# hangs for minutes on GitHub CDN addresses this lab network can't reach
# (185.199.109.133 seen 2026-10-28). CMake skips the download if the hash matches.
cpm_seed() {
  local f="$SRC/cmake_targets/CPM.cmake" v h out
  v=$(sed -nE 's/^set\(CPM_DOWNLOAD_VERSION ([0-9.]+)\)/\1/p' "$f")
  h=$(sed -nE 's/^set\(CPM_HASH_SUM "([0-9a-f]+)"\)/\1/p' "$f")
  out="$CPM_SOURCE_CACHE/cpm/CPM_$v.cmake"
  if ! echo "$h  $out" | sha256sum -c --status - 2>/dev/null; then
    mkdir -p "$(dirname "$out")"
    curl -sSfL --connect-timeout 8 --retry 3 -o "$out" \
      "https://github.com/cpm-cmake/CPM.cmake/releases/download/v$v/CPM.cmake"
    echo "$h  $out" | sha256sum -c - || { echo "build: CPM.cmake hash mismatch" >&2; exit 1; }
  fi
  echo "build: CPM.cmake $v cached in $CPM_SOURCE_CACHE"
}

# Header-only simde at the commit build_oai -I would install, kept under $LAB.
# /usr/include/simde on this host is an older hand-copied snapshot lacking e.g.
# simde_mm512_reduce_add_ps (used on AVX-512 CPUs); -I makes ours win over it.
SIMDE_INC=$LAB/src/simde-inc
simde() {
  local rev; rev=$(sed -n '/^install_simde_from_source/,/^}/p' "$SRC/cmake_targets/tools/build_helper" \
    | sed -nE 's/^ *git checkout ([0-9a-f]{40})$/\1/p' | head -1)
  [ -n "$rev" ] || { echo "simde: pinned commit not found in build_helper" >&2; exit 1; }
  [ -d "$SIMDE_INC/simde/.git" ] || git clone -q https://github.com/simd-everywhere/simde-no-tests.git "$SIMDE_INC/simde"
  git -C "$SIMDE_INC/simde" cat-file -e "$rev" 2>/dev/null || git -C "$SIMDE_INC/simde" fetch -q origin
  git -C "$SIMDE_INC/simde" checkout -q -f "$rev"
  echo "simde: $SIMDE_INC/simde at $(git -C "$SIMDE_INC/simde" log -1 --format='%h %cd' --date=short)"
}

build() {
  layout
  [ -x "$SRC/cmake_targets/build_oai" ] || { echo "build: run ./setup.sh clone first" >&2; exit 1; }
  cpm_seed
  simde
  if tmux has-session -t "$TAG-build" 2>/dev/null; then
    echo "build: tmux session $TAG-build already running" >&2; exit 1
  fi
  # nice + taskset are inherited by cmake/ninja/compilers, so the whole build stays on $CPUS
  cat > "$LAB/logs/build.sh" <<EOF
#!/usr/bin/env bash
cd "$SRC/cmake_targets" || exit 1
export CPM_SOURCE_CACHE="$CPM_SOURCE_CACHE"
# read by CMake on first configure only: after changing, delete ran_build/
export CFLAGS="-I$SIMDE_INC" CXXFLAGS="-I$SIMDE_INC"
nice -n 10 taskset -c $CPUS ./build_oai --ninja --gNB --nrUE -w SIMU --build-tool-opt -j$JOBS 2>&1 | tee "$LAB/logs/build.log"
echo "BUILD_EXIT=\${PIPESTATUS[0]}" | tee -a "$LAB/logs/build.log"
EOF
  chmod +x "$LAB/logs/build.sh"
  tmux new-session -d -s "$TAG-build" "$LAB/logs/build.sh"
  echo "build: started in tmux session $TAG-build, log $LAB/logs/build.log"
}

# Fresh copy of the tutorial core into $LAB/cn5g, then isolation + slice-2 patch.
# docker-compose-positioning.yaml is left out: unused, and it hardcodes 192.168.70.x.
cn5g() {
  layout
  local up="$SRC/doc/tutorial_resources/oai-cn5g"
  [ -f "$up/docker-compose.yaml" ] || { echo "cn5g: $up missing, run ./setup.sh clone" >&2; exit 1; }
  if [ -n "$(dk ps -q --filter "label=com.docker.compose.project=$PROJ")" ]; then
    echo "cn5g: project $PROJ is running; ./lab.sh cn-down first" >&2; exit 1
  fi
  rm -rf "$LAB/cn5g"
  mkdir -p "$LAB/cn5g"
  cp -r "$up"/{conf,database,healthscripts,docker-compose.yaml} "$LAB/cn5g/"
  python3 -I "$KIT/patch_cn5g_slices.py" "$LAB/cn5g" \
    --sub "$SUB" --proj "$PROJ" --netname "$NETNAME" --bridge "$BRIDGE"
}

# RAN configs in $LAB/conf: gnb.conf from the tutorial's band-78 106-PRB file,
# ue1..4.conf with two PDU sessions (one per slice).
conf() {
  layout
  local src="$SRC/targets/PROJECTS/GENERIC-NR-5GC/CONF/gnb.sa.band78.fr1.106PRB.usrpb210.conf"
  local dst="$LAB/conf/gnb.conf" i
  sed -e 's/snssaiList = ({ sst = 1; })/snssaiList = ({ sst = 1; }, { sst = 2; })/' \
      -e "s/amf_ip_address = ({ ipv4 = \"192.168.70.132\"; })/amf_ip_address = ({ ipv4 = \"$AMF_IP\"; })/" \
      -e "s#= \"192.168.70.129/24\";#= \"$GNB_IP/26\";#" \
      -e "s/serverport = 4043;/serverport = $RFPORT;/" \
      -e "s#IQfile = \"/tmp/rfsimulator.iqs\";#IQfile = \"$LAB/run/gnb/rfsimulator.iqs\";#" \
      "$src" > "$dst"
  # every edit must have landed exactly where expected
  grep -q 'snssaiList = ({ sst = 1; }, { sst = 2; })' "$dst" &&
  grep -q "ipv4 = \"$AMF_IP\"" "$dst" &&
  [ "$(grep -c "\"$GNB_IP/26\"" "$dst")" = 2 ] &&
  grep -q "serverport = $RFPORT;" "$dst" &&
  grep -q "IQfile = \"$LAB/run/gnb/" "$dst" &&
  ! grep -qE '192\.168\.70\.|/tmp/' "$dst" || { echo "conf: gnb.conf edit failed, upstream changed?" >&2; exit 1; }
  echo "conf: $dst"
  for i in 1 2 3 4; do
    cat > "$LAB/conf/ue$i.conf" <<EOF
# oai-lab-kit UE $i: one PDU session per slice (see doc/runmodem-nrue.md)
uicc0 = {
  imsi = "$(ue_imsi "$i")";
  key = "fec86ba6eb707ed08905757b1bb44b8f";
  opc = "C42449363BBAD02B66D16BC975D77CC1";
  pdu_sessions = (
    { id = 1; dnn = "oai";   nssai_sst = 1; ifname = "ue-embb";  },
    { id = 2; dnn = "urllc"; nssai_sst = 2; ifname = "ue-urllc"; }
  );
};
EOF
  done
  echo "conf: $LAB/conf/ue{1..4}.conf"
}

# Copy the small, shareable results of $LAB into $KIT/lab/ for git: notes, configs,
# patched core, test outputs. Not src/, build output, run logs or IQ files (large).
snapshot() {
  local d="$KIT/lab"
  rm -rf "$d"
  mkdir -p "$d/cn5g" "$d/run" "$d/logs"
  cp "$LAB/NOTES.md" "$LAB/COMMIT" "$d/"
  cp -r "$LAB/conf" "$d/"
  cp -r "$LAB/cn5g"/{conf,database,healthscripts,docker-compose.yaml} "$d/cn5g/"
  cp -r "$LAB/run/tests" "$d/run/"
  cp "$LAB/logs/cn5g.diff" "$d/logs/"
  echo "snapshot: $d ($(du -sh "$d" | cut -f1))"
}

case "${1:-}" in
  layout) layout ;;
  snapshot) snapshot ;;
  conf)   conf ;;
  clone)  clone ;;
  cn5g)   cn5g ;;
  simde)  simde ;;
  build)  build ;;
  all)    clone; build ;;
  *) echo "usage: $0 layout|clone|simde|build|cn5g|conf|snapshot|all" >&2; exit 2 ;;
esac
