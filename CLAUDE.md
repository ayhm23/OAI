# oai-lab-kit — private OAI 5G SA RF-sim testbed on a SHARED lab PC

Other users run their own OAI setups, docker containers and processes on this
machine. **Isolation from them is the top priority, above speed or convenience.**

Goal: OAI CN5G (docker) + OAI gNB + OAI nrUE (built from source), RF-simulator,
two slices end to end:
- Slice 1: SST=1 (eMBB), DNN "oai", UE pool 10.0.0.0/24, 5QI 9, iface "ue-embb"
- Slice 2: SST=2, DNN "urllc", UE pool 10.0.2.0/24, 5QI 7, session AMBR 50 Mbps, iface "ue-urllc"

Slicing here is core/session-level only: RAN slice resource partitioning is not
provided by OAI RAN (FlexRIC SLICE SM unsupported, see openair2/E2AP/README.md).
Keep the design compatible with later: dedicated UPF per slice, E2 agent +
FlexRIC KPM per slice, slice-aware MAC scheduling.

## Isolation design (must hold at all times)

All my values live in `env.sh`: LAB (root dir, default ~/oai-lab), SUB (subnet
octet), RFPORT, CPUS, JOBS, and derived TAG/PROJ/NETNAME/BRIDGE.

- Everything lives under `$LAB`: src/, cn5g/, conf/, run/, logs/. Nothing is
  written into the repo's working dirs at runtime; gNB/UE run with cwd in
  `$LAB/run/...` so their stats/log files land there.
- Core: `docker compose -p $PROJ`. Remove all fixed `container_name` entries.
  Network name `$NETNAME`, bridge name `$BRIDGE` (<=15 chars), subnet
  `192.168.$SUB.128/26`. Replace every 192.168.70.x in compose + config.yaml,
  including the ext-dn route and the P-CSCF IP.
- gNB: copy `gnb.sa.band78.fr1.106PRB.usrpb210.conf` to `$LAB/conf/gnb.conf`.
  amf_ip_address = 192.168.$SUB.132, NG/NGU addresses = 192.168.$SUB.129,
  `snssaiList = ({ sst = 1; }, { sst = 2; })`. Run with
  `--rfsim --rfsimulator.[0].serveraddr server --rfsimulator.[0].serverport $RFPORT`,
  pinned with `taskset -c $CPUS`.
- UE i (1..4, IMSI 00101000000000i, K/OPc from the tutorial DB): runs inside MY
  netns `$TAG-uei`, connected to the host by a veth pair (host 10.$SUB.i.1/24,
  ns 10.$SUB.i.2/24). Connects to the gNB at 10.$SUB.i.1:$RFPORT. Config
  `$LAB/conf/uei.conf` with two pdu_sessions (fields: id, dnn, nssai_sst, ifname).
- Core slice config: add slice 2 to the AMF plmn_support_list nssai, SMF
  smf_info, SMF local_subscription_infos, UPF upf_info, and dnns. Edit by
  exact-text anchors so YAML anchors/comments survive. Verify the result parses
  as YAML.

## Hard rules — never break these

1. Never touch anything that isn't mine. Allowed: files under `$LAB` and this
   folder, docker objects named `$PROJ*`/`$NETNAME`, netns/veth with my `$TAG`,
   tmux sessions named `$TAG-*`.
2. Never `pkill`/`killall` by program name, never `docker stop/rm/prune` on
   anything not in project `$PROJ`, and never `docker system prune`. Stop my RAN
   only by matching my config path (`$LAB/conf/`) in the command line.
3. Never do system-wide tuning: cpufreq-set, cpupower, sysctl, ethtool,
   grub/mitigations, CPU governor changes. RF-sim doesn't need them.
4. Never install, upgrade or remove apt packages, or write to /etc or
   /usr/local, without asking first and showing the exact command. Don't
   install UHD (not needed for RF-sim).
5. Compile with at most `$JOBS` jobs and `nice -n 10`. Run gNB/UE only on `$CPUS`.
6. sudo: first test with `sudo -n true`. If a command needs a password, do NOT
   try to work around it. Stop, print the exact command(s) for the user to run in
   their own terminal, and wait for them to say "done".
7. Long-running processes (gNB, UE, docker logs -f) go in detached tmux sessions
   (`$TAG-gnb`, `$TAG-ue1`, ...) with output tee'd to `$LAB/run/...`. Then read
   the log files. Never block on a foreground process.
8. Before any command that changes state outside `$LAB` (docker networks, netns,
   interfaces), say in one line what it will create, and confirm with
   `check_conflicts.sh` that it doesn't clash.
9. If something unexpected appears that might belong to another user (a
   container, interface, port or netns you didn't create), leave it alone and
   tell the user.

## Working style

- Work in phases (0 recon, 1 build, 2 core, 3 gNB, 4 UE1, 5 tests, 6 handover);
  stop at every CHECKPOINT, summarize, and wait for the user's OK.
- The user is learning OAI: explain each step briefly (2–4 sentences) and point
  out what is standard 3GPP behaviour vs OAI-specific.
- Troubleshooting: name the failed call-flow stage (NG setup / sync / RACH / RRC
  / registration / auth / PDU session / data path), quote log lines, give the
  most likely cause, propose ONE change at a time.

## Known environment facts (Phase 0 recon, 2026-10-28)

- Ubuntu 22.04.5, kernel 6.8; Ryzen 9 7950X 16C/32T; 62 GiB RAM; ~147 GB free on /.
- Pre-existing objects of other users (leave alone) are listed in
  `CLAUDE.local.md` (not in git: this repo is public). Among them is a bridge on
  192.168.70.128/26, the tutorial default subnet, hence SUB=77.
- Shared docker image cache already holds oaisoftwarealliance/*:develop,
  *:v2.0.0, mysql:8.0, trf-gen-cn5g, ims. Pulling a tag others use changes it
  for them too — ask before `docker compose pull` of shared tags.
- `oai` was added to `docker` + `sudo` groups (2026-10-28); sudo needs a
  password (rule 6 applies). Until re-login, run docker via `sg docker -c '...'`
  and have the user run root steps as `sg sudo -c "sudo ./lab.sh ..."` (plain sudo
  says "not in the sudoers file" in sessions older than the group change).
- Root is needed only for `lab.sh ue-ns <i>` / `ue-ns-down`; gNB, UE, ping, iperf
  run unprivileged (UE via an in-netns tmux server with ambient CAP_NET_ADMIN only).
- tmux 3.2a installed.
- Network: GitHub CDN 185.199.109.133 is unreachable from this lab (other
  185.199.10x.133 work). CMake's file(DOWNLOAD) hangs on it, so setup.sh
  pre-seeds CPM.cmake with curl into `$CPM_SOURCE_CACHE` (=$LAB/src/cpm-cache).
- /usr/include/simde is an old hand-copied snapshot (lacks
  simde_mm512_reduce_add_ps; this CPU has AVX-512). Don't overwrite it (shared);
  setup.sh builds with `-I$LAB/src/simde-inc` at build_helper's pinned commit.
- `build_oai -I` was NOT needed: all apt build deps were already installed.
