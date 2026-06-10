---
title: cloud-init + NetworkManager DNS on Debian genericcloud (renderer key lives under system_info)
date: 2026-06-10
tags: [devops, cloud-init, networkmanager, dns, debian, netplan]
severity: high
---

## Problem
In the image built by `linux-debian/debian_qcow2.sh`, DNS from Proxmox cloud-init did not reach `/etc/resolv.conf`, even though the IP came up ("cloud-init works, but DNS doesn't").

## Root Cause
Three competing network-management layers. The base Debian genericcloud (13/trixie) ships `netplan.io` + `systemd-networkd` (`networkctl`), has **no** `ifupdown` and **no** `NetworkManager`, and `/etc/resolv.conf` is a symlink to the systemd-resolved stub (`127.0.0.53`). Without `network.renderers`, cloud-init picks **netplan** from its default priority (→ networkd backend). The script added a SECOND file `/etc/netplan/01-network-manager-all.yaml` with `renderer: NetworkManager` on the same `eth0`. Two renderers on one interface = conflict; the nameservers were never registered with systemd-resolved → empty resolv.conf.

## Solution
Single source of truth: force cloud-init to the `network-manager` renderer and remove the hand-written netplan.

GOTCHA (confirmed in cloud-init 25.1.4): the renderer key is read from `Distro._cfg`, and `Distro._cfg == the system_info block` (`stages.py` → `_extract_cfg("system")`). `network_renderer()` reads the path `("network","renderers")`. So ONLY this works:
```yaml
system_info:
  network:
    renderers: ["network-manager"]
```
A top-level `network: renderers:` is silently IGNORED (cloud-init falls back to the default netplan→networkd).

Offline proof: `cloud-init devel net-convert -p netcfg.yaml -k yaml -D debian -m eth0,<mac> -O network-manager` on a Proxmox-style network-config v1 (static subnet + `type: nameserver`) produces a keyfile with `dns=192.168.1.1;8.8.8.8;` and `dns-search=...`. The NM renderer requires NetworkManager to be installed in the image (the `available()` check looks for `nmcli`).

## References
- linux-debian/debian_qcow2.sh
- cloud-init 25.1.4: cloudinit/distros/__init__.py:361-371 (`network_renderer`), cloudinit/stages.py:166-172 + 185-194 (`_extract_cfg("system")`)
- related: [[1781052000-networkd-wait-online-120s-boot-hang]]
