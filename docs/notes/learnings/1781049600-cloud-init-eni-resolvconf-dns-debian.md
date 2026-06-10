---
title: cloud-init DNS on Debian genericcloud via eni + resolvconf (and the libguestfs --link gotcha)
date: 2026-06-10
tags: [devops, cloud-init, eni, resolvconf, dns, debian, libguestfs]
severity: high
---

## Problem
Unify both image builds on ifupdown and make Proxmox cloud-init DNS (and DHCP DNS) reliably reach `/etc/resolv.conf` on Debian 13.

## Root Cause / findings
- The cloud-init renderer is selected from `system_info: network: renderers: [...]` (confirmed in cloud-init 25.1.4: `Distro._cfg == system_info` block, `network_renderer()` reads `("network","renderers")`). A top-level `network: renderers:` is silently IGNORED. For ifupdown use `renderers: ["eni"]`.
- cloud-init's **eni renderer places `dns-nameservers` on the `lo` interface** (not the physical one) in `/etc/network/interfaces.d/50-cloud-init`. The `systemd-resolved` if-up hook `/etc/network/if-up.d/resolved` **exempts lo**, so with systemd-resolved DNS is lost (this is the original "cloud-init doesn't set DNS on Debian 13" bug; matches Proxmox forum + cloud-init #5318).
- **resolvconf does NOT exempt lo** — verified live: `resolvconf -l` shows `# resolv.conf from lo.inet` + `nameserver 1.1.1.1 / 9.9.9.9`. So removing systemd-resolved and using resolvconf makes the lo-placed DNS work, with NO relocation fixup script.

## Solution (both scripts)
1. `apt-get purge -y systemd-resolved`; `--install resolvconf`. (ifupdown comes via `ifenslave`; DHCP client is `dhcpcd`, which integrates with resolvconf.)
2. cloud-init image: drop-in `system_info: network: renderers: ["eni"]`; also `--uninstall netplan.io`. no-cloud-init image: ship `/etc/network/interfaces` = lo + `source interfaces.d/*` + netui-owned `interfaces.d/eth0`.
3. **GOTCHA:** set `/etc/resolv.conf` -> `/run/resolvconf/resolv.conf` with `virt-customize --link`, NOT `--run-command 'ln -sf'`. libguestfs swaps `/etc/resolv.conf` for the appliance's network during `--run-command`/`--install` and **restores the original (the dead systemd-resolved stub symlink) afterwards**, silently reverting any in-guest `ln -sf`. Without the link, `/etc/resolv.conf` stays a dangling symlink to `../run/systemd/resolve/stub-resolv.conf` even though resolvconf has the data in `/run/resolvconf/resolv.conf`.

## Verification (live qemu/KVM)
- cloud-init image + Proxmox-style NoCloud seed (static + `type: nameserver`): `/etc/resolv.conf` -> `/run/resolvconf/resolv.conf` showing `nameserver 1.1.1.1 / 9.9.9.9 / search example.lan`.
- no-cloud-init image + DHCP: `/etc/resolv.conf` shows the DHCP nameserver, `getent hosts` resolves. No duplicate eth0; boot ~30s (wait-online masked).

## References
- linux-debian/debian_qcow2.sh, linux-debian/debian_qcow2-no-cloud-init.sh (the `[   DNS]` blocks)
- cloud-init 25.1.4: cloudinit/distros/__init__.py (`network_renderer`), cloudinit/stages.py (`_extract_cfg("system")`)
- related: [[1781052000-networkd-wait-online-120s-boot-hang]]
