# oai-lab-kit

Private OAI 5G SA RF-sim testbed (OAI CN5G in docker + gNB + nrUE from source) with two
slices — SST 1/DNN `oai` and SST 2/DNN `urllc` — isolated from other users of a shared host.
Rules for agents: `CLAUDE.md`. Results, problems and fixes: `~/oai-lab/NOTES.md`
(copy in [`lab/NOTES.md`](lab/NOTES.md)).

`lab/` is a snapshot of `~/oai-lab` made by `./setup.sh snapshot`: notes, OAI commit, gNB/UE
configs, the patched core (compose + config.yaml, diff vs. upstream in `lab/logs/cn5g.diff`)
and the raw ping/iperf3 outputs. Sources, build output and run logs are not included.
The DB/UE credentials in it are the public OAI tutorial defaults.

| File | Purpose |
|---|---|
| `env.sh` | every value (LAB, SUB, RFPORT, CPUS, JOBS, TAG, …) and derived names; `dk` docker wrapper |
| `setup.sh` | `layout`, `clone`, `simde`, `build` (tmux, pinned, niced), `cn5g` (copy + patch core), `conf` (gnb/ue configs), `snapshot` (refresh `lab/`) |
| `patch_cn5g_slices.py` | isolation edits to the tutorial compose + slice 2 in config.yaml, exact-text anchored, YAML-verified |
| `check_conflicts.sh` | read-only clash check: `cn`, `gnb`, `ue <i>`, `all` |
| `lab.sh` | runtime: `cn-up`, `cn-down`, `cn-logs`, `gnb`, `ue-ns <i>` (root), `ue <i>`, `ue-ip`, `ping`, `iperf`, `status`, `stop`, `down`, `ue-ns-down` (root) |

Quick start: `./lab.sh cn-up && ./lab.sh gnb && sudo ./lab.sh ue-ns 1 && ./lab.sh ue 1 && ./lab.sh ping 1 urllc`.
Teardown: `./lab.sh down && sudo ./lab.sh ue-ns-down all && ./lab.sh status`.
