---
title: cloud-init + NetworkManager DNS na Debian genericcloud (klucz renderera pod system_info)
date: 2026-06-10
tags: [devops, cloud-init, networkmanager, dns, debian, netplan]
severity: high
---

## Problem
W obrazie z `linux-debian/debian_qcow2.sh` DNS z Proxmox cloud-init nie trafiał do `/etc/resolv.conf`, mimo że IP się podnosiło ("cloud-init działa, ale DNS nie").

## Root Cause
Trzy konkurujące warstwy zarządzania siecią. Bazowy Debian genericcloud (13/trixie) ma `netplan.io` + `systemd-networkd` (`networkctl`), **brak** `ifupdown` i `NetworkManager`, a `/etc/resolv.conf` to symlink na stub systemd-resolved (`127.0.0.53`). cloud-init bez `network.renderers` wybiera z domyślnej kolejności **netplan** (→ backend networkd). Skrypt dokładał DRUGI plik `/etc/netplan/01-network-manager-all.yaml` z `renderer: NetworkManager` na tym samym `eth0`. Dwa renderery na jednym interfejsie = konflikt; nameservery nie rejestrowały się w systemd-resolved → pusty resolv.conf.

## Solution
Jedno źródło prawdy: zmusić cloud-init do renderera `network-manager` i usunąć ręczny netplan.

GOTCHA (potwierdzone w cloud-init 25.1.4): klucz renderera czytany jest z `Distro._cfg`, a `Distro._cfg == blok system_info` (`stages.py` → `_extract_cfg("system")`). `network_renderer()` bierze ścieżkę `("network","renderers")`. Więc działa TYLKO:
```yaml
system_info:
  network:
    renderers: ["network-manager"]
```
Top-level `network: renderers:` jest po cichu IGNOROWANY (cloud-init wraca do domyślnego netplan→networkd).

Dowód offline: `cloud-init devel net-convert -p netcfg.yaml -k yaml -D debian -m eth0,<mac> -O network-manager` na network-config v1 w stylu Proxmoxa (subnet static + `type: nameserver`) daje keyfile z `dns=192.168.1.1;8.8.8.8;` oraz `dns-search=...`. Renderer NM zachowuje warunek: NM musi być zainstalowany w obrazie (sprawdzenie `available()` szuka `nmcli`).

## References
- linux-debian/debian_qcow2.sh
- cloud-init 25.1.4: cloudinit/distros/__init__.py:361-371 (`network_renderer`), cloudinit/stages.py:166-172 + 185-194 (`_extract_cfg("system")`)
