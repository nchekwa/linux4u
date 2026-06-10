## Network / DNS — image build (debian_qcow2.sh)

- **Rule:** The target network stack for the cloud-init image (`linux-debian/debian_qcow2.sh`) is **NetworkManager** — a single manager, with `nmtui` kept. DNS comes from **Proxmox cloud-init** (Cloud-Init panel: IP + `nameserver`) and must be applied inside the VM. cloud-init must render the network via NetworkManager (`renderers: ["network-manager"]`) so that the IP and DNS from the Proxmox datasource reach NM, and from there `/etc/resolv.conf`.
- **Context:** Previously three layers competed in the image (cloud-init→networkd + a hand-written netplan `renderer: NetworkManager` + systemd-resolved) → DNS from DHCP/cloud-init never reached `/etc/resolv.conf`. The `debian_qcow2-no-cloud-init.sh` variant removes cloud-init and uses ifupdown+dhclient — DNS works there because dhclient writes resolv.conf itself.
- **Updated:** 2026-06-10

## Boot — systemd-networkd-wait-online (120s hang)

- **Rule:** In the cloud-init image (`debian_qcow2.sh`) we mask `systemd-networkd-wait-online.service`. Since NetworkManager manages the network, systemd-networkd manages nothing, and this waiter (enabled by the genericcloud preset, default 120s timeout) blocks `network-online.target` for the full 120s on every boot. `NetworkManager-wait-online` covers `network-online.target` (~0.4s).
- **Context:** Confirmed on a live VM: `systemd-analyze blame` → `2min systemd-networkd-wait-online.service`. Details: [[1781052000-networkd-wait-online-120s-boot-hang]].
- **Updated:** 2026-06-10
