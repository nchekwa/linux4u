---
title: 120s boot hang — systemd-networkd-wait-online on an NM/ifupdown-managed image
date: 2026-06-10
tags: [devops, systemd, networkd, networkmanager, boot, cloud-init, debian]
severity: high
---

## Problem
A VM from the cloud-init image boots in ~5s, then stalls for **exactly ~120s** before reaching the login prompt.

## Root Cause
`systemd-networkd-wait-online.service` is enabled by the base genericcloud **preset** (`/usr/lib/systemd/system-preset/*.preset: enable systemd-networkd-wait-online.service`) and has `ExecStart=/usr/lib/systemd/systemd-networkd-wait-online` **without `--timeout`** → default **120s** timeout, `WantedBy=network-online.target`.

After switching to the NetworkManager renderer (DNS fix: `renderers: ["network-manager"]`), **systemd-networkd manages no link**, so the waiter never sees an "online" link and runs out the full 120s, blocking `network-online.target` (pulled in by, among others, `cloud-init-network.service`).

The "exactly 120s" signature uniquely points to this service (for comparison: `NetworkManager-wait-online`/`nm-online` = 30s, ifupdown/dhclient ~60s).

Confirmed on a live VM:
```
systemd-analyze blame  ->  2min 0.071s  systemd-networkd-wait-online.service
                            0.422s       NetworkManager-wait-online.service   (the real waiter, fast)
systemd-analyze critical-chain -> ~120s gap: networking.service @3.7s  ->  cloud-init-network.service @2min3.9s
```

## Solution
Mask the networkd waiter (it is redundant on an NM/ifupdown stack; `NetworkManager-wait-online` covers `network-online.target`):
```
virt-customize -a $FILE_PATH --run-command 'systemctl mask systemd-networkd-wait-online.service'
```
On an already-running VM, immediately: `sudo systemctl mask systemd-networkd-wait-online.service && sudo reboot` → boot drops from ~2min to ~7s.

NOTE: in plain qemu (user-net / socket without carrier) the hang did NOT reproduce (boot ~15s) — it needs a real environment (Proxmox/bridge), so the diagnosis is confirmed by `systemd-analyze` from the target VM, not by a local test.

## References
- linux-debian/debian_qcow2.sh (block "[    NM] Mask systemd-networkd-wait-online")
- related: [[1781049600-cloud-init-nm-renderer-dns-debian]]
