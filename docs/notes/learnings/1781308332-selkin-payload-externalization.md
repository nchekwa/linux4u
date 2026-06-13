---
title: Externalizing builder payloads without breaking single-file distribution
date: 2026-06-13
tags: [devops, libguestfs, virt-customize, envsubst, selkin]
severity: medium
---

## Problem

`debian_qcow2-selkin.sh` embedded its systemd units and start scripts as inline
`cat << EOF` heredocs. Because the heredocs sat inside double-quoted
`--run-command "..."` strings, every runtime shell variable had to be escaped
(`\${DISPLAY}`, `\${HOME}`, `\"`). The result was unlintable, no syntax
highlighting, and error-prone to edit. The constraint: the builder must remain a
SINGLE file you can `curl` to a host and run — extracting payloads must not
require checking out a folder.

## Root Cause

Two competing pulls: heredocs keep distribution single-file but make the
payloads unmaintainable; a plain "extract to repo + `--copy-in` from local repo"
approach makes payloads clean but breaks single-file distribution.

A third trap: fetching payloads with `--run-command 'wget ...'` (in-guest) would
inherit the build-time DNS-swap problem — the `[DNS]` block swaps
`/etc/resolv.conf` inside the libguestfs appliance, so in-guest fetches after it
fail to resolve names (see devops.md Network/DNS rule).

## Solution

Keep payloads as real files in `linux-debian/selkin/`; the single-file builder
pulls them at build time and injects them with `--copy-in`:

- **`curl` on the HOST**, not in-guest. Host networking is unaffected by the
  appliance DNS swap, and there is no build-step ordering constraint. Fetch into
  a `mktemp -d` dir cleaned by `trap 'rm -rf "$BUILD_TMP"' EXIT`.
- **`--copy-in "$BUILD_TMP/file:/dest/dir"`** to place files (dest dir must exist
  first; virt-customize runs options in command-line order, so a `--run-command
  'mkdir -p ...'` earlier in the same call works).
- **Templated payloads use `.tpl`** and are rendered with a RESTRICTED envsubst
  variable list: `envsubst '${DESKTOP_USER}'`. This is the key trick — envsubst
  substitutes ONLY the listed names, leaving runtime `${HOME}`/`${DISPLAY}`/
  `${XDG_RUNTIME_DIR:-/tmp}` literal. Without the list, envsubst would clobber
  every `$VAR` it found in the environment.
- **Secrets** (`SELKIES_PASSWORD`, `VNC_PASSWORD`) stay as host env vars, filled
  by envsubst at build time, never committed to the public repo.
- **Reproducibility:** the raw base `LINUX4U_REPO` is pinned to `LINUX4U_REF`
  (default `main`); set it to a tag/SHA for a reproducible build. Otherwise the
  image is a function of whatever is on `main` at build time. The vars are
  repo-scoped (raw root), so the `linux-debian/selkin/` subpath is appended in
  the fetch helpers. `netui` uses the same base (`${LINUX4U_REPO}/bin/netui`),
  fetched host-side + `--copy-in` instead of the old in-guest `wget`.
- Robust fetch in `sh` (no `pipefail`): `curl -fsSL ... -o tmpfile || exit 1`
  THEN `envsubst < tmpfile`, so a failed download is caught instead of feeding
  a truncated stream into envsubst.
- Requires `gettext-base` (provides `envsubst`) on the host.

`99-eni.cfg` was left inline: 3-line static cloud-init config, not a script, no
escaping pain — extracting it would add a network fetch for nothing.

## References

- `linux-debian/debian_qcow2-selkin.sh` (helpers `fetch_payload` / `render_tpl`)
- `linux-debian/selkin/*.tpl`, `linux-debian/selkin/quick_upgrade.sh`
- devops.md: "Selkin image — externalized payloads", "Network / DNS — image build"
