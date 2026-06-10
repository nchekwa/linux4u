---
title: 120s boot hang — systemd-networkd-wait-online on an ifupdown-managed image
date: 2026-06-10
tags: [devops, systemd, networkd, networkmanager, boot, cloud-init, debian]
severity: high
---

## Problem
A VM from the cloud-init image boots in ~5s, then stalls for **exactly ~120s** before reaching the login prompt.

## Root Cause
`systemd-networkd-wait-online.service` is enabled by the base genericcloud **preset** (`/usr/lib/systemd/system-preset/*.preset: enable systemd-networkd-wait-online.service`) and has `ExecStart=/usr/lib/systemd/systemd-networkd-wait-online` **without `--timeout`** → default **120s** timeout, `WantedBy=network-online.target`.

Because networking is managed by ifupdown (cloud-init renders via the eni renderer), **systemd-networkd manages no link**, so the waiter never sees an "online" link and runs out the full 120s, blocking `network-online.target` (pulled in by, among others, `cloud-init-network.service`). (This was first observed while the cloud-init image used the NetworkManager renderer; the cause — networkd managing nothing — is identical now that it uses ifupdown/eni.)

The "exactly 120s" signature uniquely points to this service (for comparison: `NetworkManager-wait-online`/`nm-online` = 30s, ifupdown/dhclient ~60s).

Confirmed on a live VM:
```
systemd-analyze blame  ->  2min 0.071s  systemd-networkd-wait-online.service
                            0.422s       NetworkManager-wait-online.service   (the real waiter, fast)
systemd-analyze critical-chain -> ~120s gap: networking.service @3.7s  ->  cloud-init-network.service @2min3.9s
```

## Solution
Mask the networkd waiter (systemd-networkd is not the manager; ifupdown/dhcpcd bring the link up):
```
virt-customize -a $FILE_PATH --run-command 'systemctl mask systemd-networkd-wait-online.service'
```
On an already-running VM, immediately: `sudo systemctl mask systemd-networkd-wait-online.service && sudo reboot` → boot drops from ~2min to ~7s.

NOTE: in plain qemu (user-net / socket without carrier) the hang did NOT reproduce (boot ~15s) — it needs a real environment (Proxmox/bridge), so the diagnosis is confirmed by `systemd-analyze` from the target VM, not by a local test.

## References
- linux-debian/debian_qcow2.sh + debian_qcow2-no-cloud-init.sh (the "Mask systemd-networkd-wait-online" blocks; both images mask it)
- related: [[1781049600-cloud-init-eni-resolvconf-dns-debian]]
