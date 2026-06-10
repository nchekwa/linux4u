## Network / DNS — image build (debian_qcow2.sh)

- **Rule:** Docelowy stack sieci w obrazie z cloud-init (`linux-debian/debian_qcow2.sh`) to **NetworkManager** — jeden zarządca, zachowane `nmtui`. DNS pochodzi z **Proxmox cloud-init** (panel Cloud-Init: IP + `nameserver`) i ma zostać zastosowany w VM. cloud-init musi renderować sieć przez NetworkManager (`renderers: ["network-manager"]`), żeby IP i DNS z datasource Proxmoxa trafiły do NM, a stamtąd do `/etc/resolv.conf`.
- **Context:** Wcześniej w obrazie konkurowały 3 warstwy (cloud-init→networkd + ręczny netplan `renderer: NetworkManager` + systemd-resolved) → DNS z DHCP/cloud-init nie trafiał do `/etc/resolv.conf`. Wariant `debian_qcow2-no-cloud-init.sh` usuwa cloud-init i używa ifupdown+dhclient — tam DNS działa, bo dhclient sam zapisuje resolv.conf.
- **Updated:** 2026-06-10
