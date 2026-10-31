#!/usr/bin/env python3
"""Patch a fresh copy of OAI's tutorial CN5G (doc/tutorial_resources/oai-cn5g)
for this lab: isolation edits (compose) + slice 2 (config.yaml).

Edits are exact-text anchored so YAML anchors/comments survive; every anchor
must match exactly once, otherwise nothing is written. The result is parsed
back with PyYAML and checked semantically.

usage: patch_cn5g_slices.py <cn5g dir> --sub 77 --proj P --netname N --bridge B
"""
import argparse
import pathlib
import re
import sys

import yaml

SLICE2 = {"sst": 2, "dnn": "urllc", "pool": "10.0.2.0/24", "5qi": 7, "ambr": "50Mbps"}


def replace_once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit(f"anchor for '{what}' matched {n} times (expected 1); upstream changed?")
    return text.replace(old, new)


def patch_compose(text, a):
    if text.startswith("name:"):
        sys.exit("docker-compose.yaml already patched; re-copy from upstream first")
    n = len(re.findall(r"^\s+container_name:.*\n", text, flags=re.M))
    text = re.sub(r"^\s+container_name:.*\n", "", text, flags=re.M)
    print(f"compose: removed {n} container_name entries")
    text = replace_once(text, "name: oai-cn5g-public-net", f"name: {a.netname}", "network name")
    text = replace_once(text, 'com.docker.network.bridge.name: "oai-cn5g"',
                        f'com.docker.network.bridge.name: "{a.bridge}"', "bridge name")
    n = text.count("192.168.70.")
    text = text.replace("192.168.70.", f"192.168.{a.sub}.")
    print(f"compose: rewrote {n} occurrences of 192.168.70. -> 192.168.{a.sub}.")
    # project name inside the file too, so a bare `docker compose` here still targets mine
    return f"# patched by oai-lab-kit: project/network/bridge/subnet isolated\nname: {a.proj}\n" + text


def patch_config(text, a):
    if "&urllc_slice" in text:
        sys.exit("config.yaml already patched; re-copy from upstream first")
    s = SLICE2
    # YAML anchor for the new slice, next to the existing eMBB one
    text = replace_once(text,
        "  - &embb_slice\n    sst: 1\n",
        "  - &embb_slice\n    sst: 1\n"
        f"  - &urllc_slice\n    sst: {s['sst']}\n", "snssais anchors")
    # AMF: slice supported in the PLMN (goes into NG Setup Response / Allowed NSSAI)
    text = replace_once(text,
        "      nssai:\n        - *embb_slice\n",
        "      nssai:\n        - *embb_slice\n        - *urllc_slice\n", "amf plmn_support_list nssai")
    # SMF: advertise slice+DNN to NRF so the AMF selects this SMF for it
    text = replace_once(text,
        '          - dnn: "default"\n  local_subscription_infos:\n',
        '          - dnn: "default"\n'
        "      - sNssai: *urllc_slice\n        dnnSmfInfoList:\n"
        f'          - dnn: "{s["dnn"]}"\n'
        "  local_subscription_infos:\n", "smf smf_info")
    # SMF: local subscription = QoS profile for (slice 2, urllc)
    text = replace_once(text,
        '        session_ambr_dl: "10Gbps"\n\nupf:\n',
        '        session_ambr_dl: "10Gbps"\n'
        f"    - single_nssai: *urllc_slice\n      dnn: \"{s['dnn']}\"\n      qos_profile:\n"
        f"        5qi: {s['5qi']}\n"
        f"        session_ambr_ul: \"{s['ambr']}\"\n        session_ambr_dl: \"{s['ambr']}\"\n"
        "\nupf:\n", "smf local_subscription_infos")
    # UPF: advertise slice+DNN to NRF so the SMF selects this UPF for it
    text = replace_once(text,
        '          - dnn: "default"\n\nlmf:\n',
        '          - dnn: "default"\n'
        "      - sNssai: *urllc_slice\n        dnnUpfInfoList:\n"
        f'          - dnn: "{s["dnn"]}"\n'
        "\nlmf:\n", "upf upf_info")
    # DNN -> UE IP pool
    text = replace_once(text,
        '    ipv4_subnet: "10.0.255.0/24"\n    ipv6_prefix: "2001:1:2::/64"',
        '    ipv4_subnet: "10.0.255.0/24"\n    ipv6_prefix: "2001:1:2::/64"\n'
        f'  - dnn: "{s["dnn"]}"\n    pdu_session_type: "IPV4"\n    ipv4_subnet: "{s["pool"]}"',
        "dnns")
    if not text.endswith("\n"):
        text += "\n"
    n = text.count("192.168.70.")
    text = text.replace("192.168.70.", f"192.168.{a.sub}.")
    print(f"config: added slice 2 in 6 places, rewrote {n} occurrences of 192.168.70. (P-CSCF)")
    return text


def verify(compose, config, a):
    c = yaml.safe_load(compose)
    k = yaml.safe_load(config)
    s = SLICE2
    net = c["networks"]["public_net"]
    assert c["name"] == a.proj
    assert net["name"] == a.netname
    assert net["driver_opts"]["com.docker.network.bridge.name"] == a.bridge
    assert net["ipam"]["config"][0]["subnet"] == f"192.168.{a.sub}.128/26"
    assert not any("container_name" in v for v in c["services"].values())
    for doc in (compose, config):
        assert "192.168.70." not in doc
    sl2 = {"sst": s["sst"]}
    assert sl2 in k["amf"]["plmn_support_list"][0]["nssai"]
    assert any(e["sNssai"] == sl2 and {"dnn": s["dnn"]} in e["dnnSmfInfoList"]
               for e in k["smf"]["smf_info"]["sNssaiSmfInfoList"])
    lsi = [e for e in k["smf"]["local_subscription_infos"]
           if e["single_nssai"] == sl2 and e["dnn"] == s["dnn"]]
    assert len(lsi) == 1 and lsi[0]["qos_profile"]["5qi"] == s["5qi"]
    assert lsi[0]["qos_profile"]["session_ambr_dl"] == s["ambr"]
    assert any(e["sNssai"] == sl2 and {"dnn": s["dnn"]} in e["dnnUpfInfoList"]
               for e in k["upf"]["upf_info"]["sNssaiUpfInfoList"])
    assert any(d["dnn"] == s["dnn"] and d["ipv4_subnet"] == s["pool"] for d in k["dnns"])
    # slice 1 untouched
    assert {"sst": 1} in k["amf"]["plmn_support_list"][0]["nssai"]
    assert any(d["dnn"] == "oai" and d["ipv4_subnet"] == "10.0.0.0/24" for d in k["dnns"])
    assert k["smf"]["ims"]["pcscf_ipv4"] == f"192.168.{a.sub}.139"
    print("verify: both files parse as YAML; isolation + slice 1/2 checks passed")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("dir", type=pathlib.Path)
    p.add_argument("--sub", required=True, type=int)
    p.add_argument("--proj", required=True)
    p.add_argument("--netname", required=True)
    p.add_argument("--bridge", required=True)
    a = p.parse_args()
    if len(a.bridge) > 15:
        sys.exit(f"bridge name {a.bridge} > 15 chars")
    cf, kf = a.dir / "docker-compose.yaml", a.dir / "conf" / "config.yaml"
    compose = patch_compose(cf.read_text(), a)
    config = patch_config(kf.read_text(), a)
    verify(compose, config, a)
    cf.write_text(compose)
    kf.write_text(config)
    print(f"wrote {cf} and {kf}")


if __name__ == "__main__":
    main()
