---
title: cloud-init image — eth0 DOWN without a datasource, and the clean DHCP fallback
date: 2026-06-13
tags: [devops, network, cloud-init, ifupdown, dhcp, debian]
severity: high
---

## Problem

A VM built from `debian_qcow2-cloud-init.sh` and booted on Proxmox **without** a
cloud-init drive came up with `eth0` down:

```
2: eth0: <BROADCAST,MULTICAST> mtu 9000 qdisc noop state DOWN
```

`qdisc noop` = `ifup` was never run on eth0. `hostname` stayed `localhost`
(cloud-init never set it). Expectation was "no cloud-init => plain DHCP".

## Root Cause

Debian `genericcloud` ships **no static eth0 stanza** — the only thing that
creates `/etc/network/interfaces.d/*` for eth0 is cloud-init's eni renderer at
boot. But Debian's `ds-identify` runs first with the default policy
`search,found=all,maybe=all,notfound=disabled`: when **no datasource** is found
it writes `disabled-by-generator` and cloud-init does not run at all. So nothing
renders eth0, `networking.service` raises only `lo`, and eth0 stays
`qdisc noop state DOWN`. (Confirmed live: `cloud-init status` → `disabled`,
`/etc/network/interfaces.d/` empty, `networking.service` active/success.)

The tempting "fix" — force cloud-init on with `ds-identify` `notfound=enabled` —
was tested on live qemu/KVM VMs and **rejected**, because it drags in two
regressions:

1. **~240s boot hang.** With the default datasource list, cloud-init's network
   stage probes the EC2 IMDS `http://169.254.169.254/.../instance-id` with a 50s
   timeout, looping to 240s. (Constraining `datasource_list: [NoCloud, ConfigDrive, None]`
   fixes the hang but, alone, ds-identify still disables cloud-init.)
2. **`networking.service` failed / system `degraded`.** cloud-init 25.1.4
   **hardcodes** `dhcp4: True, dhcp6: True` in `net.generate_fallback_config()`
   (no config knob), so the eni renderer emits both `iface eth0 inet dhcp` and
   `iface eth0 inet6 dhcp`. IPv4 comes up via dhcpcd (which also does IPv6 via RA),
   but the separate `inet6 dhcp` stanza makes `ifup` look for a dedicated DHCPv6
   client, finds none (`No DHCPv6 client software found!` — Debian 13 dropped
   `isc-dhcp-client`; the image standardises on dhcpcd) and fails the whole unit.
   Installing `wide-dhcpv6-client` made it WORSE (two failed units). Stripping the
   `inet6` line before `networking.service` worked at boot but cloud-init's network
   stage re-adds it → fragile.

`SYSTEM_CFG` (`network:` in `/etc/cloud/cloud.cfg.d`) is checked **before** the
datasource in `Init._find_networking_config`, so a global network config would
override a real Proxmox datasource — not acceptable. `DataSourceNone` has no
`network_config` hook either.

## Solution

Don't fight Debian (don't force cloud-init on) and don't add a separate file or
service — **pre-seed cloud-init's own render path** at build time:

```
mkdir -p /etc/network/interfaces.d
cat > /etc/network/interfaces.d/50-cloud-init <<EOF
auto eth0
iface eth0 inet dhcp
EOF
```

Why this is the clean answer:
- **No datasource:** ds-identify disables cloud-init, which never touches the file →
  the pre-seeded DHCP default stays → ifupdown brings eth0 up on DHCP. dhcpcd does
  IPv6 via RA (no `inet6` stanza → no DHCPv6 failure).
- **Datasource present:** cloud-init **OVERWRITES this exact file** with the
  datasource config. SINGLE file → no duplicate `eth0` stanza, no service/script.

Two alternatives were live-tested and REJECTED:
1. **Force cloud-init on** (`ds-identify` `notfound=enabled`) → ~240s EC2 IMDS probing
   + the hardcoded dual-stack fallback's `inet6 dhcp` failure (above).
2. **Separate static `interfaces.d/eth0`** (or a `netcfg-fallback` oneshot that writes
   it): cloud-init writes a SEPARATE `50-cloud-init`, so WITH a datasource both files
   are sourced. With matching DHCP it's tolerated, but when the datasource pushes a
   **static IP** the result is broken — eth0 ended up with BOTH `10.0.2.50` (static)
   AND a DHCP lease `10.0.2.15`, default route via the wrong (DHCP) address. The
   `netcfg-fallback` oneshot also re-wrote `eth0` every boot, clobbering any `netui`
   static config.

Verified on live qemu/KVM boots (incl. the full real `debian_qcow2-cloud-init.sh`):
- **No datasource:** cloud-init `disabled`, eth0 `UP` on DHCP, `networking.service`
  success, no `inet6` error, no EC2 hang.
- **NoCloud datasource, static v1 config:** cloud-init overwrites `50-cloud-init`,
  eth0 = `10.0.2.50` ONLY (no DHCP pollution), clean.

Gotchas worth remembering:
- cloud-init's eni renderer writes to `/etc/network/interfaces.d/50-cloud-init` and
  **overwrites** it; it does NOT merge or write elsewhere. Pre-seeding that path is safe.
- A network-config **v2** seed with `routes:`/`addresses:` made cloud-init's local stage
  ERROR (eni renderer); use **v1** (`type: physical` / `subnets: [{type: static, ...}]`)
  for eni-rendered static configs.
- `netui` owns `interfaces.d/eth0` (a DIFFERENT file). In the cloud-init images the
  network authority is cloud-init/datasource; mixing `sudo netui` here would create a
  second eth0 stanza.

## References

- `linux-debian/debian_qcow2-cloud-init.sh` and `debian_qcow2-cloud-init-selkies.sh` (pre-seed `50-cloud-init` block)
- Binding rule: `docs/notes/devops.md` → "Network — eth0 DHCP default when cloud-init has no datasource"
- Related: [[1781049600-cloud-init-eni-resolvconf-dns-debian]], [[1781052000-networkd-wait-online-120s-boot-hang]]
