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
ext-dn 192.168.77.195 (N6 network `oailab77-n6`, 192.168.77.192/26, bridge `br-oailab77n6`; UPF N6 .194), UE i netns `oailab77-uei`, veth `voailab77hi` (host, 10.77.i.1) ↔
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
                                         #    (slice-limit is applied automatically; n6-gro only for the eBPF UPF)
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

**Session AMBR 50 Mbit/s on slice 2 is enforced with `tc` in my ext-dn, not by the core.** The SMF signals
it to the UE (and with `enable_qers: yes` sends QERs), but the simple-switch UPF does not police, and the
eBPF datapath (the only one with QER code) misbehaves here (see `REPORT-2026-11-25.md`). So `./lab.sh
slice-limit` (auto on `cn-up`, rate = `SLICE2_RATE` in `env.sh`) shapes DL and polices UL for 10.0.2.0/24
inside ext-dn: URLLC 47.9 / 45.9 Mbit/s DL/UL, eMBB 338 / 159 unaffected. Needs `enable_snat: no` so ext-dn
sees the UE source IPs. Non-3GPP, contained in my container.

**URLLC latency (~3-7 ms RTT) is expected**: eMBB radio config (TDD period 5 ms, 30 kHz SCS) and no RAN
slicing in OAI; the 2026-10-28 "URLLC is faster" averages were warm-up noise (minimums both ~5 ms).

## Link capacity: radio, gNB, UE, core

**One cell, one radio link.** gNB and UE share the same carrier; there is no separate "UE capacity" and no
per-slice radio capacity (OAI has no RAN slicing). Both UEs/slices compete for the same PRBs and slots.

| Item | Value | Where set / 3GPP or OAI-specific |
|---|---|---|
| Band / carrier | n78, SSB ARFCN 641280, point A 640008 → centre ≈ 3619.2 MHz (`-C 3619200000` on the UE) | `gnb.conf`, UE command line (3GPP bands, OAI-specific CLI) |
| Numerology | µ=1: 30 kHz SCS, 0.5 ms slots, 20 slots/frame | `*_subcarrierSpacing = 1` |
| Bandwidth | 106 PRB × 12 sc × 30 kHz ≈ 38.2 MHz occupied (a "40 MHz" channel); UE told with `-r 106` | `dl/ul_carrierBandwidth = 106` |
| Antennas / layers | 1T1R, 1 MIMO layer | `RUs: nb_tx = 1, nb_rx = 1` |
| TDD pattern | 5 ms period: 7 DL slots + 1 special (6 DL, 4 UL symbols, 4 flexible) + 2 UL slots | `dl_UL_TransmissionPeriodicity = 6`, `nrofDownlinkSlots = 7`, `nrofUplinkSlots = 2`, symbols 6/4 |
| Time share | DL ≈ 74 % (7 + 6/14 of 10 slots), UL ≈ 23 % (2 + 4/14) | derived |
| Modulation | MCS table 0 (up to 64QAM), OAI default max MCS 28 DL | OAI MAC defaults |
| Channel | AWGN, no fading (RF-sim `modelname = "AWGN"`); UE sees SNR ≈ 17–46 dB, CQI 15 | `rfsimulator` block |
| CPUs | gNB and UE pinned to `12-15,28-31` (`taskset`) | `env.sh` `CPUS` |

**Rough theoretical peak (my estimate, not measured):** about 100–120 Mbit/s downlink and about 35 Mbit/s
uplink for 106 PRB, 1 layer, 64QAM at top MCS, after DMRS/PDCCH/CSI-RS overhead. UL is lower because of
the 2-slot UL window and a lower UL MCS cap.

**Measured, and why it differs.** iperf3 counts *wall-clock* seconds, but RF-sim has no real-time clock:
simulated air time advances as fast as the CPUs process slots. Measured by counting the gNB's
`Frame.Slot` log lines (one per 128 frames = 1.28 s of air time) against wall time, while iperf ran
(`embb`, 12 s, approximate wall time):

| Direction | iperf (wall clock) | Simulation speed | Real-time-equivalent capacity |
|---|---|---|---|
| Downlink | 333 Mbit/s | ≈ 4.1× real time | ≈ 82 Mbit/s |
| Uplink | 160 Mbit/s | ≈ 4.8× real time | ≈ 33 Mbit/s |
| Idle | n/a | ≈ 5.9× real time | n/a |

So the real-time-equivalent figures agree with the theoretical bound (DL a bit under it, UL close to it),
and the headline 330 / 160 Mbit/s are **CPU-bound simulation rates, not radio capacity**. More cores in `CPUS`
raise them; a second UE roughly halves each UE's share (226–230 Mbit/s each) because the same slots and
the same CPUs are shared. nrUE is the heaviest process (~150–180 % CPU each).

**Where a rate limit can live (and what is actually in force):**

| Layer | Mechanism | State in this lab |
|---|---|---|
| Radio (gNB/UE) | PRBs, TDD pattern, MCS, 1 layer, UE-AMBR | physical limit above; OAI gNB does not enforce UE-AMBR or per-slice PRBs |
| Core, 3GPP | session AMBR via SMF → UPF QER | signalled to UE (NAS), QER sent with `enable_qers: yes`; simple-switch UPF does not police; eBPF UPF does but misbehaves here |
| Core, this lab | `tc` in my ext-dn (`./lab.sh slice-limit`, `SLICE2_RATE`) | slice 2 (10.0.2.0/24) held at 50 Mbit/s DL/UL: measured 47.9 / 45.9 Mbit/s; slice 1 unrestricted: 338 / 159 Mbit/s |
| Transport | N3 MTU 1600 in compose (GTP-U adds ~44 B to a 1500 B packet) | needed by the eBPF UPF (cannot fragment); the simple-switch UPF also works with 1500 |

Latency floor from the same config: one TDD period (5 ms) for an uplink round trip; see
`REPORT-2026-11-25.md`.

## Slice parameter reference — what each config file sets

A slice is identified end to end by **S-NSSAI** (SST, optional SD; here SST only → UE requests `sst.ffffff`,
"no SD") plus a **DNN**. The same two values must be consistent in all three files below:

| | Slice 1 — eMBB | Slice 2 — URLLC |
|---|---|---|
| S-NSSAI | SST 1 | SST 2 |
| DNN | `oai` | `urllc` |
| UE IP pool (UPF) | 10.0.0.0/24 | 10.0.2.0/24 |
| 5QI / default QoS flow | 9 (non-GBR) | 7 (non-GBR) |
| Session AMBR (signalled) | 10 Gbps UL/DL | 50 Mbps UL/DL |
| PDU session id on the UE | 1 | 2 |
| UE interface / routing table | `ue-embb` / 10001 | `ue-urllc` / 10002 |
| gNB DRB | DRB 1 (QFI 1, 5QI 9) | DRB 2 (QFI 1, 5QI 7) |
| UPF `upf_info` | `*embb_slice` + dnn `oai`, … | `*urllc_slice` + dnn `urllc` |
| Real limit in force | none | `tc` 50 Mbit/s in ext-dn |

### 1. `~/oai-lab/conf/gnb.conf` — the RAN (derived from `gnb.sa.band78.fr1.106PRB.usrpb210.conf`)

| Parameter | Value | Meaning |
|---|---|---|
| `gNB_ID`, `gNB_name`, `nr_cellid` | 0xe00, `gNB-OAI`, 12345678 | identity sent in NG Setup |
| `tracking_area_code` | 1 | must match the AMF `plmn_support_list` `tac: 0x0001` |
| `plmn_list` | MCC 001, MNC 01 (2 digits) | PLMN broadcast in SIB1; must match AMF and the UE IMSI prefix 00101 |
| **`snssaiList`** | `({ sst = 1; }, { sst = 2; })` | **the slices this gNB supports**: announced in NG Setup, the AMF answers with them (`Supported slice … SST=0x01`, `0x02`); a slice missing here makes PDU session setup fail. Only this list is slice-aware on the RAN side; OAI MAC does not partition resources by slice |
| `physCellId`, `absoluteFrequencySSB`, `dl_absoluteFrequencyPointA`, `dl/ul_frequencyBand` | 0, 641280, 640008, 78 | cell identity and frequency raster (≈ 3619.2 MHz SSB) |
| `dl/ul_subcarrierSpacing`, `dl/ul_carrierBandwidth`, `initial*BWP*` | 1 (30 kHz), 106 PRB | numerology and bandwidth: the capacity table above |
| `prach_*`, `preamble*`, `ra_ContentionResolutionTimer`, `msg1_*` | tutorial defaults | RACH (4-step CBRA) tuning; works as shipped |
| `ssb_periodicityServingCell`, `ssb_PositionsInBurst_Bitmap`, `ssPBCH_BlockPower` | 2 (20 ms), 1, −25 | SSB timing and power |
| `dl_UL_TransmissionPeriodicity`, `nrofDownlink/UplinkSlots/Symbols` | 6, 7, 6, 2, 4 | TDD frame structure → latency floor and DL/UL split |
| `do_CSIRS`, `do_SRS` | 1, `periodic` | CSI-RS and SRS on: DL link adaptation, UL channel sounding |
| `amf_ip_address` | 192.168.77.132 | AMF (N2/NGAP, SCTP 38412) in my subnet |
| `GNB_IPV4_ADDRESS_FOR_NG_AMF`, `…_FOR_NGU`, `GNB_PORT_FOR_NGU` | 192.168.77.129/26 (both), 2152 | gNB's own N2 and N3 (GTP-U) addresses = host side of `br-oailab77` |
| `MACRLCs`: `pusch_TargetSNRx10`, `pucch_TargetSNRx10` | 150, 200 | UL power-control targets (15 dB / 20 dB) |
| `L1s`: `prach_dtx_threshold`, `pucch0_dtx_threshold` | 120, 100 | detection thresholds |
| `RUs`: `nb_tx/nb_rx`, `att_tx/att_rx`, `max_rxgain`, `bands` | 1/1, 12/12, 114, [78] | 1T1R and RF gains; in RF-sim these only set signal levels |
| `rfsimulator`: `serveraddr = "server"`, `serverport = 4077`, `modelname = "AWGN"` | | gNB is the rfsim *server*; port 4077 is mine (upstream 4043 left free) |
| `security` | ciphering `nea0`, integrity `nia2`, `nia0` | AS algorithms the gNB prefers; DRB ciphering "yes", DRB integrity "no" |
| `log_config` | `ngap`/`f1ap` debug, rest info | NG setup and PDU session handling are visible in `gnb.log` |

Launch (`run/gnb/run.sh`): `taskset -c 12-15,28-31 nr-softmodem -O conf/gnb.conf --gNBs.[0].min_rxtxtime 6
--rfsim --rfsimulator.[0].serveraddr server --rfsimulator.[0].serverport 4077`, cwd `$LAB/run/gnb` so the
`nr*_stats.log` files land there. `--gNBs.[0].min_rxtxtime 6` is an OAI gNB option (the minimum number of slots between a reception and the
matching transmission, i.e. processing time given to the UE); it is the value OAI's own tutorials use with RF-sim,
I did not tune it.

### 2. `~/oai-lab/conf/ue1.conf` … `ue4.conf` — the UE (identical except IMSI)

```
uicc0 = {
  imsi = "00101000000000<i>";           # 001 01 + MSIN: PLMN and subscriber
  key  = "fec86ba6eb707ed08905757b1bb44b8f";   # K (tutorial test value, same in core DB)
  opc  = "C42449363BBAD02B66D16BC975D77CC1";   # OPc
  pdu_sessions = (
    { id = 1; dnn = "oai";   nssai_sst = 1; ifname = "ue-embb";  },
    { id = 2; dnn = "urllc"; nssai_sst = 2; ifname = "ue-urllc"; }
  );
};
```
- `imsi`, `key`, `opc`: SIM identity for 5G-AKA; must match the subscriber row in the core database
  (`oai_db.sql`, all four IMSIs 001010000000001…4 use the same tutorial K/OPc). Wrong key → authentication failure.
- `pdu_sessions` (an OAI-specific list; upstream's default is a single session): the UE sends **one PDU Session
  Establishment Request per entry** after registration. `id` is the PDU session ID, `dnn` and `nssai_sst`
  are what the SMF/AMF use to pick the slice and the pool, `ifname` is the Linux TUN device the UE creates
  for it (`ue-embb`, `ue-urllc`). OAI then adds `ip rule from/to <ip> lookup 1000N` + a default route
  per interface so traffic bound to a slice IP leaves through that slice's TUN.
- Not in the file, but set on the command line (`run/ue<i>/run.sh`): `-r 106 --numerology 1 --band 78
  -C 3619200000` (must equal the gNB cell) and `--rfsimulator.[0].serveraddr 10.77.<i>.1 --rfsimulator.[0].serverport 4077`
  (the UE connects to the gNB through its own veth pair, host side 10.77.<i>.1). The UE runs inside netns
  `oailab77-ue<i>`, pinned to the same `CPUS`.
- Note: the UE requests `NSSAI sst.ffffff` ("no SD"); the gNB list and the core use SST only, so they match.

### 3. `~/oai-lab/cn5g/conf/config.yaml` — the core (one file for all NFs; slice-relevant parts)

Edited by exact-text anchors in `patch_cn5g_slices.py`; a YAML anchor `&urllc_slice` is defined next to
`&embb_slice` under `snssais:` and reused (`*urllc_slice`) everywhere below, so the slice is defined once.

| Section | Slice-2 entry added | Role |
|---|---|---|
| `snssais` | `- &urllc_slice` / `sst: 2` | defines the S-NSSAI once |
| `amf.plmn_support_list[0].nssai` | `- *urllc_slice` | **AMF admits slice 2** for PLMN 001/01, TAC 1 (registration/allowed NSSAI) and returns it in NG Setup |
| `smf.smf_info.sNssaiSmfInfoList` | `sNssai: *urllc_slice` + `dnn: "urllc"` | SMF advertises which slice/DNN it serves to the NRF (3GPP TS 29.510 SmfInfo); the AMF discovers the SMF with it (`enable_smf_selection: yes`) |
| `smf.local_subscription_infos` | `single_nssai: *urllc_slice`, `dnn: "urllc"`, `5qi: 7`, `session_ambr_ul/dl: "50Mbps"` | **QoS of the slice**: used instead of UDM data because `use_local_subscription_info: yes`. This is where 5QI and AMBR come from (no slice-2 row exists in `oai_db.sql`; that DB only holds SST 1 / SD FFFFFF) |
| `smf.upfs` | `host: oai-upf` and a second entry `host: 192.168.77.134`, each `enable_qers: yes` | SMF per-UPF features; the NRF-discovered UPF is matched by IP, hence two entries |
| `upf.upf_info.sNssaiUpfInfoList` | `sNssai: *urllc_slice` + `dnn: "urllc"` | UPF registers the slice with the NRF, so the SMF selects it for slice-2 sessions (extend later with a dedicated second UPF) |
| `dnns` | `dnn: "urllc"`, `ipv4_subnet: "10.0.2.0/24"`, IPv4 | **UE IP pool per DNN**: slice 2 UEs get 10.0.2.x, slice 1 gets 10.0.0.x |
| `upf.support_features` | `enable_bpf_datapath: no`, `enable_snat: no` | simple-switch UPF; no NAT so ext-dn sees real UE IPs (needed for the `tc` limit) |
| `upf.remote_n6_gw`, `nfs.upf.n3/n6.interface_name` | 192.168.77.195, `eth0` / `eth1` | N6 on its own interface (only used by the eBPF UPF; harmless otherwise) |
| `smf.ue_mtu`, `smf.ims.pcscf_ipv4` | 1500, 192.168.77.139 | MTU signalled to the UE; P-CSCF in my subnet (every `192.168.70.x` rewritten to `192.168.77.x`) |

Flow for slice 2: UE requests PDU session (sst 2, `urllc`) → AMF checks `plmn_support_list` → NRF returns an
SMF whose `smf_info` has that slice+DNN → SMF takes QoS from `local_subscription_infos`, picks the pool from
`dnns`, asks the NRF for a UPF whose `upf_info` has that slice+DNN → N4 session (PFCP) to the UPF → N2 PDU
Session Resource Setup to the gNB (5QI 7 → DRB 2). 3GPP: all of these steps; OAI-specific: local subscription
infos, the YAML-anchor config style, and one config file for every NF.

### Supporting files that must agree with the three above

- `cn5g/docker-compose.yaml`: services, fixed addresses (AMF .132, UPF .134 N3 / .194 N6, ext-dn .195),
  networks `oailab77-net` (192.168.77.128/26, bridge `br-oailab77`, MTU 1600) and `oailab77-n6`
  (192.168.77.192/26, bridge `br-oailab77n6`); ext-dn route `10.0.0.0/16 via UPF`, TX offload off.
- `cn5g/database/oai_db.sql`: subscribers (IMSI, K, OPc, SQN) and SST-1 session data used by the UDR/UDM.
- `env.sh`: `SUB`, `RFPORT`, `CPUS`, `SLICE2_POOL`, `SLICE2_RATE`; everything above is derived from it.

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
