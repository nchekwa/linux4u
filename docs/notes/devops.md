## Network / DNS — image build (both debian_qcow2 scripts)

- **Rule:** Both images unify on **ifupdown + standard `/etc/network/`**, configured by the `netui` whiptail TUI (`bin/netui`, shipped to `/usr/local/bin/netui`). DHCP by default; static is set via `sudo netui` (incl. its "Capture DHCP lease -> static" action). NetworkManager and ceni are NOT used. The cloud-init image (`debian_qcow2.sh`) forces cloud-init to render via the **eni** renderer (`system_info: network: renderers: ["eni"]`). The no-cloud-init image removes cloud-init and ships `/etc/network/interfaces` = `lo` + `source /etc/network/interfaces.d/*` with a netui-owned `interfaces.d/eth0` (DHCP) + seeded `/etc/network/netui/eth0/main.conf`.
- **DNS:** `systemd-resolved` is removed; **resolvconf** manages `/etc/resolv.conf` (ifupdown `dns-*` options + dhcpcd). `/etc/resolv.conf` MUST be linked to `/run/resolvconf/resolv.conf` via `virt-customize --link` — NOT `--run-command 'ln -sf'`, which libguestfs reverts because it swaps `/etc/resolv.conf` for appliance networking during `--run-command`/`--install` and restores the original afterwards. Verified on live VMs: Proxmox cloud-init nameservers AND DHCP nameservers both land in `/etc/resolv.conf`.
- **Context:** Supersedes the earlier rule "cloud-init image uses the NetworkManager renderer" (commit b199fa3). The user chose to unify both images on ifupdown+netui+resolvconf. cloud-init's eni renderer places `dns-nameservers` on `lo`, but resolvconf (unlike the systemd-resolved if-up hook, which exempts lo) DOES capture lo-placed DNS, so no relocation fixup is needed. See [[1781049600-cloud-init-eni-resolvconf-dns-debian]].
- **Updated:** 2026-06-10

## Boot — systemd-networkd-wait-online (120s hang)

- **Rule:** Mask `systemd-networkd-wait-online.service` in BOTH images. systemd-networkd is not the manager (ifupdown is), so this waiter (enabled by the genericcloud preset, default 120s timeout) blocks `network-online.target` for the full 120s. The no-cloud-init image does not pull `network-online.target` today (so it would not hang), but it is masked there too for consistency.
- **Context:** Confirmed on a live VM: `systemd-analyze blame` → `2min systemd-networkd-wait-online.service`. Details: [[1781052000-networkd-wait-online-120s-boot-hang]].
- **Updated:** 2026-06-10
