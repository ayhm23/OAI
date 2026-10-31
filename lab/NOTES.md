# oai-lab NOTES — private OAI 5G SA RF-sim testbed with 2 slices

Built and verified 2026-10-28 on the shared lab PC (Ubuntu 22.04.5, Ryzen 9 7950X).
Kit (scripts): `/home/oai/Desktop/oai-lab-kit` — rules for future sessions in its `CLAUDE.md`.

## Chosen values (`env.sh`)

| Var | Value | Why |
|---|---|---|
| LAB | `~/oai-lab` | everything I create lives here |
| SUB | `77` | core 192.168.77.128/26, UE links 10.77.i.0/24; 70 is the tutorial default and another user's bridge already uses it |
| RFPORT | `4077` | upstream default 4043 left free for others |
| CPUS | `12-15,28-31` | 4 physical cores + their SMT siblings (verified with `lscpu -e`), same NUMA node/L3; idle at selection time |
| JOBS | `8` | build runs `nice -n 10 taskset -c $CPUS` |
| TAG / PROJ / NETNAME / BRIDGE | `oailab77` / `oailab77-cn` / `oailab77-net` / `br-oailab77` | TAG set explicitly, not from `$USER` |

Derived: AMF 192.168.77.132, gNB NG/NGU 192.168.77.129 (host side of `br-oailab77`),
ext-dn 192.168.77.135, UE i netns `oailab77-uei`, veth `voailab77hi` (host, 10.77.i.1) ↔
`voailab77ni` (netns, 10.77.i.2), tmux socket/session `oailab77-uei`.

## Versions

- OAI RAN: duranta-project/openairinterface5g `develop` @ **cfee4c20b45ac1cf6d455d3f01bb3e00200438b0**
  (2026-10-23, integration_2026_w43) — also in `~/oai-lab/COMMIT`
- simde (header-only, local): simde-no-tests @ 1c68d9a (the commit `build_oai -I` pins)
- CN5G images: oai-{nrf,amf,smf,upf,udr,udm,ausf}:v2.2.1, mysql:9.6, trf-gen-cn5g:latest, ims:latest (pre-existing, not re-pulled)

## Layout

```
~/oai-lab/
  COMMIT  NOTES.md
  src/openairinterface5g/   repo (build in cmake_targets/ran_build/build)
  src/simde-inc/simde/      pinned simde headers (-I)
  src/cpm-cache/            CMake CPM downloads (instead of ~/.cache/cpm)
  cn5g/                     patched tutorial core (compose + conf/config.yaml)
  conf/                     gnb.conf, ue1..4.conf
  run/gnb/  run/ueN/        cwd of the softmodems: logs + nr*_stats.log
  run/cn/                   saved core logs     run/tests/  ping/iperf outputs
  logs/                     build.log, cn5g.diff, cn-up.log
```

## Start order

```bash
cd ~/Desktop/oai-lab-kit
# one-time setup (already done)
./setup.sh clone && ./setup.sh build     # build in tmux oailab77-build
./setup.sh cn5g && ./setup.sh conf       # core copy+patch, RAN configs
# run
./lab.sh cn-up                           # 1. core (conflict check, pull missing images, wait healthy)
./lab.sh gnb                             # 2. gNB (tmux oailab77-gnb)
sg sudo -c "sudo ./lab.sh ue-ns 1"       # 3. ROOT once per UE: netns+veth+in-netns tmux
./lab.sh ue 1                            # 4. UE inside its netns
./lab.sh ue-ip 1; ./lab.sh ping 1 embb; ./lab.sh ping 1 urllc
./lab.sh iperf 1 embb; ./lab.sh iperf 1 urllc
```
(`sg sudo -c` is only needed until you log out/in once; same for docker, which the
scripts already wrap with `sg docker` when needed.)

## Stop order

```bash
./lab.sh stop                            # UEs, then gNB (core keeps running)
./lab.sh down                            # + core, tmux sessions/servers
sg sudo -c "sudo ./lab.sh ue-ns-down all"  # ROOT: delete netns (veth pairs go with them)
./lab.sh status                          # should show nothing of mine
```
RAN processes are stopped only by matching `~/oai-lab/conf/` in their command line
(SIGINT, then SIGKILL after 10 s). Never by program name.

## How to verify each step

| Step | Command | Expect |
|---|---|---|
| core | `./lab.sh status`, `./lab.sh cn-logs oai-amf 300 \| grep -A2 "Slice Support"` | 10 containers healthy; AMF `SST 1`, `SST 2` |
| slices in SMF/UPF | `./lab.sh cn-logs oai-smf 600 \| grep -E "DNN urllc\|5qi\|session_ambr"` | `DNN urllc: First UE IPv4: 10.0.2.2`, 5qi 7, 50Mbps |
| NG setup | `grep -E "NGSetupResponse\|Supported slice" ~/oai-lab/run/gnb/gnb.log` | `Received NGSetupResponse`, slices 0x01 and 0x02 |
| rfsim server | `ss -ltnp "( sport = :4077 )"` | `nr-softmodem` listening |
| UE attach | `grep -E "SIB1 decoded\|RA procedure succeeded\|Registration Accept\|successfully configured" ~/oai-lab/run/ue1/ue.log` | all four, two TUNs |
| UE IPs | `./lab.sh ue-ip 1` | `ue-embb 10.0.0.x`, `ue-urllc 10.0.2.x`, ip rules tables 10001/10002 |
| per-slice SMF | `./lab.sh cn-logs oai-smf 3000 \| grep -A1 "Create SM Context Request"` | one request with sst 1, one with sst 2 |

## UE 1 call flow as observed (`run/ue1/ue.log`)

1. **Cell search / SSB** — `Initial sync: pbch decoded sucessfully` → `Initial sync successful, PCI: 0`. (3GPP: PSS/SSS/PBCH → MIB.)
2. **SIB1** — `SIB1 decoded`: RACH config, TDD pattern, PLMN. (3GPP.)
3. **RACH** — 4-step CBRA: Msg1 preamble 50 → `RAR-Msg2 decoded` → `RA-Msg3 transmitted` → `Contention Resolution is successful`. (3GPP 38.321.)
4. **RRC setup** — `Received NR_RRCSetup` → `NR_RRC_CONNECTED`; RRCSetupComplete carries the NAS Registration Request. (3GPP 38.331.)
5. **Registration/auth** — `FGS_AUTHENTICATION_REQUEST` (5G-AKA, keys kausf→kseaf→kamf printed by OAI), `FGS_SECURITY_MODE_COMMAND` (nea0 / nia2), AS security, UE capability, `Registration Accept` with 5G-GUTI. (3GPP 24.501/33.501.)
6. **PDU session 1** — requested `NSSAI 1.ffffff DNN oai` → Accept, `ue-embb 10.0.0.2`.
7. **PDU session 2** — requested `NSSAI 2.ffffff DNN urllc` → Accept, `ue-urllc 10.0.2.2`.
   OAI-specific: the UE adds `ip rule from/to <ip> table 1000N` + default route via the TUN, inside its netns.

SMF side: two `Create SM Context Request` for imsi-001010000000001 — sst 1/oai/10.0.0.2/5QI 9/AMBR 10 Gbps
and sst 2/urllc/10.0.2.2/5QI 7/AMBR 50 Mbps — both on UPF 192.168.77.134.

## Test results (ping 20 × 0.2 s; iperf3 10 s downlink `-R`, bound to the slice IP; receiver rate)

| Scenario | UE | Slice | Ping min/avg/max (ms) | Loss | DL throughput |
|---|---|---|---|---|---|
| 1 UE | 1 | eMBB (SST1, 10.0.0.2) | 5.36 / 14.03 / 142.0 | 0% | 320 Mbit/s |
| 1 UE | 1 | URLLC (SST2, 10.0.2.2) | 5.02 / 6.06 / 7.10 | 0% | 328 Mbit/s |
| 2 UEs | 1 | eMBB | 6.71 / 20.23 / 208.0 | 0% | 226 Mbit/s |
| 2 UEs | 1 | URLLC | 5.63 / 15.87 / 147.3 | 0% | 227 Mbit/s |
| 2 UEs | 2 | eMBB (10.0.0.3) | 6.51 / 30.03 / 210.5 | 0% | 230 Mbit/s |
| 2 UEs | 2 | URLLC (10.0.2.3) | 2.47 / 8.61 / 11.26 | 0% | 230 Mbit/s |

Raw outputs: `~/oai-lab/run/tests/`. The large max values are the first packet(s) of a run
(UE idle → scheduling request/grant). With 2 UEs: my 8 CPUs ~50 % busy at idle traffic
(UEs ~180 % + ~150 %, gNB ~56 %), other 24 CPUs ~1 %, zero gNB timing warnings. RF-sim
advances "air time" only as fast as all participants process slots, so throughput scales with
CPU, not radio — the 2-UE drop is expected. More cores in CPUS is the lever if needed.

**Session AMBR 50 Mbit/s on slice 2 is NOT enforced** (328 Mbit/s measured). Evidence: the
SMF logs `Session AMBR Uplink 50Mbps, Downlink 50Mbps` and sends it in NAS, but its PFCP
session establishment contains only PDR/FAR, no QER; the UPF log has no QER/MBR at all;
the gNB logs no AMBR handling. So with CN v2.2.1 + simple-switch UPF, AMBR is signalled,
not policed. Options if enforcement matters (one at a time): (a) police 10.0.2.0/24 with
`tc` inside *my* ext-dn/UPF container (non-3GPP shaping, but contained); (b) try a UPF
datapath/implementation that implements QERs (e.g. a dedicated slice-2 UPF — see below).

## Problems hit and fixes

1. **No docker/sudo/tmux** for `oai` at recon → admin added `oai` to `docker` and `sudo` groups and installed tmux.
   Existing login sessions keep their old group list: docker via `sg docker -c` (wrapped in `env.sh` `dk()`),
   sudo failed with "oai is not in the sudoers file" → run as `sg sudo -c "sudo ..."` (or log out/in).
2. **CMake configure hung** (SYN-SENT to 185.199.109.133): CPM bootstrap downloads `CPM.cmake` from GitHub;
   that CDN address is unreachable from this lab and `file(DOWNLOAD)` has no connect timeout.
   Fix: `setup.sh` pre-seeds it with `curl --connect-timeout` and checks the repo's SHA256; CMake then skips the download.
3. **CPM cache outside $LAB** (`~/.cache/cpm`) → `CPM_SOURCE_CACHE=$LAB/src/cpm-cache` in `env.sh`.
4. **Old system simde** (`/usr/include/simde`, hand-copied, lacks `simde_mm512_reduce_add_ps`; this CPU has AVX-512
   so OAI compiles its AVX-512 paths) → implicit declaration, would fail at link. Not overwritten (shared);
   fix: pinned simde in `$LAB/src/simde-inc`, build with `CFLAGS/CXXFLAGS=-I$LAB/src/simde-inc` (fresh build dir).
   `build_oai -I` was never needed: all apt build deps were present.
5. Pinned-commit extraction first matched asn1c's `git checkout` in `build_helper` → restricted to `install_simde_from_source`.
6. **Shared image cache**: `ims:latest` already existed → `cn-pull` pulls only images missing locally, `up --pull never`.
7. **sudo resets HOME to /root** → `env.sh` resolves `$LAB` from `$SUDO_USER`'s home.
8. **UE privileges**: running the UE as root would give it CAP_SYS_NICE, and OAI then pins threads to fixed CPUs,
   overriding `taskset`. Instead the in-netns tmux server runs as `oai` with only ambient CAP_NET_ADMIN (capsh).
   The gNB needs no privileges at all (threads report "no affinity, default priority").
9. `lab.sh`: a command function shadowed the `ue_ns` name helper from `env.sh` (would recurse) — renamed before first use.

## Isolation notes / caveats

- rfsim server listens on `*:4077` (all interfaces, incl. the LAN). It's unauthenticated; stop the gNB when not in use.
- Core `log_level: debug` is very verbose (UPF ~500k lines / 15 min) into docker's json logs on the shared disk;
  for long runs set `log_level: general: info` in `~/oai-lab/cn5g/conf/config.yaml` and restart the core.
- Other users' objects (a bridge on 192.168.70.128/26, containers) were seen and left alone; listed only in the kit's untracked `CLAUDE.local.md`.

## Extending later

- **Dedicated UPF per slice**: add a second UPF service in `cn5g/docker-compose.yaml` (next free IP, e.g. .140),
  move the `*urllc_slice` entry from the first UPF's `upf_info` to the new one's; SMF selects by NRF (S-NSSAI, DNN).
- **E2 / FlexRIC KPM**: build with `--build-e2`; `gnb.conf` has `e2_agent.near_ric_ip_addr = "127.0.0.1"` — on this
  shared host run *my* RIC on a distinct address/port (e.g. on `br-oailab77`) so my agent can't attach to someone else's RIC.
  Per openair2/E2AP/README.md, KPM indications need the UE to support slice (1, 0xffffff) — UEs here have it.
- **Slice-aware MAC scheduling**: RAN slice partitioning isn't in OAI RAN (FlexRIC SLICE SM unsupported), so slicing
  here is core/session-level only; the gNB already announces both S-NSSAIs, which is the hook a slice-aware scheduler needs.
