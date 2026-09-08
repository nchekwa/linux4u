---
title: Selkies 1.6.2 (WebRTC) -> 2.x (WebSocket) migration for the qcow2 image
date: 2026-09-07
tags: [selkies, webrtc, websocket, cloudflare, libguestfs, python, wheels]
severity: high
---

## Problem

The Selkies image built by `linux-debian/debian_qcow2-cloud-init-selkies.sh`
could not be reached through an HTTP reverse proxy or Cloudflare's orange-cloud.
Symptom is misleading: **the page loads, basic-auth succeeds, and the desktop
never paints**. It looks like an application hang, not a network problem.

## Root Cause

The builder installed Selkies from GitHub `releases/latest`. That is **v1.6.2,
which is WebRTC-only** — it has no `--mode` flag at all (48 args, `mode` not
among them). WebRTC carries media over UDP/SRTP; a Cloudflare proxy terminates
only HTTP/HTTPS on a fixed port list and forwards no UDP. Signalling (SDP/ICE)
travels over HTTPS and succeeds, then media negotiation completes with no
usable candidate pair. The image also shipped **no TURN** (empty `turn_host` →
Google STUN only), so there was no relay fallback either.

WebSocket transport exists **only in Selkies 2.x**, which upstream has never
tagged: `releases/latest` still resolves to v1.6.2 (2024-08-15).

## Solution

Pin the untagged commit `be53b2c39670ccd1432fe50ebcd6d0ade72ce80a` and run with
`--mode=websockets`. Frames then travel over a single outbound TCP connection on
:8080, indistinguishable from ordinary HTTPS to a proxy.

### Non-obvious findings (all verified by running the code, 2026-09-07)

1. **`--mode=websockets` alone is NOT enough.** `enable_dual_mode` defaults to
   **`True`** (`settings.py:502`), which lets the web client switch itself back
   to WebRTC at runtime. `--enable_dual_mode=false` is mandatory.

2. **Commit choice is load-bearing.** HEAD of `main` pins `pixelflux~=2.1.0`
   and `pcmflux~=2.1.0`; **only 2.0.0 exists on PyPI**, so HEAD cannot be
   installed at all. `be53b2c` is the last commit before that pin
   (`7c40254` introduced it).

3. **Do NOT strip the WebRTC deps.** linuxserver.io's Dockerfile `sed`s `av` and
   `cryptography` out of `pyproject.toml`. At `be53b2c` that **breaks startup
   even in websockets mode**, because `__main__.py:21` imports `webrtc_mode` at
   **module level** (it was a lazy in-function import at the older `348bc4f`).
   Cost of keeping them: ~35 MB.

4. **`xkbcommon` is NOT a Python dependency at this commit.** It was at
   `348bc4f`. Here `input_handler.py:88` does
   `ctypes.CDLL("libxkbcommon.so.0")` — so the guest needs the **apt** package
   `libxkbcommon0`, and nothing has to compile. The whole dependency tree
   installs from prebuilt wheels (`pip download --only-binary=:all:` succeeds).

5. **The web client is not in the source tarball.** Upstream bundles it into
   released wheels only. Without a build, Selkies dies with
   `No module named 'selkies.selkies_web'`. It must be compiled with vite
   (`addons/selkies-web-core`, ~70 ms) and passed via `--web_root`. There is
   **no upstream lockfile**, so `npm install` is not reproducible.

6. **Every flag the old builder passed still parses.** All 18 verified present
   in 2.x `settings.py`. `x264enc` is silently aliased to `h264enc`
   (`settings.py:1201`), and `turn_*` still parses but is **never read** in
   websockets mode.

### Two bugs caught only by actually running the install

- **`pip download` never stores selkies itself.** It resolves the *dependencies*
  of a URL/source install but saves no artifact for the package, so a later
  `pip install --no-index` fails with `No matching distribution found for
  selkies`. Fix: `pip wheel --no-deps` to build the selkies wheel **and**
  `pip download --only-binary=:all:` for the deps, into the same directory.

- **`pip` and `python3` can be different interpreters.** On the build host
  `pip` was 3.12 while `python3` was 3.13, producing a `cp312` wheelhouse that
  a 3.13 venv refuses (`No matching distribution found for msgpack` — the wheel
  is present but ABI-incompatible). Always `python3 -m pip`, never bare `pip`.
  Because binary wheels are ABI-tagged, the builder now **fails fast** unless
  host Python == guest Python (Debian 13 = 3.13), and Debian 12 (3.11) is
  rejected outright.

## Follow-up: this verification was INSUFFICIENT

Everything below was run **on the build host**, not inside the image. The host
already had `libva` installed, so `import pixelflux` succeeded there and failed
in a clean image — the built VM served HTTP 200 and streamed no video at all.
See [[1788825600-selkies-libva-pixelflux-import]]. The builder now runs an
`ldd` sweep + import check **inside the guest** so this cannot recur.

## Verification performed

Ran the real binary against a real `Xvfb :99`:

```
INFO:selkies.__main__:Initiating server with websockets mode
INFO:stream_server:Using custom web_root directory: .../dist
INFO:main:Initializing DataStreamingServer with encoder: h264enc, Framerate: 30
```

- `curl` without credentials → **401**; with basic auth → **200**, serving the
  vite-built `selkies-core.js`.
- WebSocket handshake on `/api/websockets` → **`HTTP/1.1 101 Switching
  Protocols`** (the endpoint is defined in `selkies.py:5641`; `/api/ws` in
  `webrtc_mode.py` is the WebRTC-mode one).
- `ss -unp` for the process → **zero UDP sockets**. This is the actual proof
  the transport changed.
- Offline install into a venv from the wheelhouse with `--no-index` → success.

## References

- Builder: `linux-debian/debian_qcow2-cloud-init-selkies.sh` (`[SELKIE]` block)
- Runtime: `linux-debian/selkies/start-selkies.sh.tpl`
- Analysis that prompted this: `docs/notes/learnings/webrtc-vs-ws.md`
- Upstream: <https://github.com/selkies-project/selkies>
- Cloudflare proxied ports: <https://developers.cloudflare.com/fundamentals/reference/network-ports/>

## Known follow-up (not fixed here)

The image serves HTTPS with the **snakeoil** cert
(`/etc/ssl/certs/ssl-cert-snakeoil.pem`). Cloudflare **Full (strict)** will
reject that origin — use a Cloudflare Origin CA cert or set the mode to Full.
Pre-existing, out of scope for the transport change, but it surfaces
immediately once WebSocket streaming works.
