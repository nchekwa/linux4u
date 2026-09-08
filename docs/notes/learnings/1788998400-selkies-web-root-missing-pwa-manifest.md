---
title: Selkies web root shipped the streaming core, not the client — no PWA manifest, no install
date: 2026-09-08
tags: [selkies, pwa, manifest, vite, web_root, virt-customize, basic-auth]
severity: medium
---

## Problem

A running image served the desktop over the browser perfectly — video, audio, input,
clipboard, resize — but no browser ever offered to install it as an app. No install
icon in the Chrome omnibox, nothing under "Add to Home Screen" on iOS.

Nothing logged an error. `journalctl -u selkies` was clean, HTTP returned 200, and the
build had passed every check.

## Root Cause

The builder shipped the wrong vite bundle as `--web_root`.

Upstream has **two** web addons, and the names do not say which is which:

| addon | what it is |
| --- | --- |
| `addons/selkies-web-core` | the streaming core alone — WebCodecs decode, input, signaling |
| `addons/selkies-dashboard` | the actual web client, which *imports* the core |

`selkies-web-core/dist/index.html` is 128 bytes:

```html
<!DOCTYPE html><html><script type="module" crossorigin src="./selkies-core.js"></script><body><div id="app"></div></body></html>
```

No `<link rel="manifest">`, no icons, no `apple-mobile-web-app-*` meta. A browser has
nothing to build an install entry from, so it silently offers none. Only
`selkies-dashboard` carries `public/manifest.json`, `icon-512.png` and a `<head>`
that links them.

The symptom hides well because the core is genuinely complete as a *stream*: it is
`selkies-core.js` that does all the work the user can see. The missing piece is inert
metadata.

A second, quieter contributor: `selkies-core.js` does `fetch("manifest.json")` purely
to override `document.title`, and swallows the failure with `.catch(() => {})`. So the
404 left no trace anywhere.

## Why the build guard did not catch it

```sh
[ -f "${BUILD_TMP}/src/addons/selkies-web-core/dist/index.html" ] || fail
```

The stub *is* an `index.html`. The assertion tested the one property that was never in
doubt.

## Fix

Mirror upstream `scripts/ci/build-web.sh`, which is what produces the browser payload
inside a released wheel: build `selkies-web-core` **first** (the dashboard's
`prebuild`/`postbuild` lift `selkies-core.js` and the gamepad DB out of its `dist/`),
then build `selkies-dashboard` with `SELKIES_INJECT=1`, and `--copy-in` the
**dashboard's** `dist/`.

The guard now asserts what actually matters:

```sh
for _f in index.html manifest.json icon-512.png; do
  [ -f "${WEB_DIST}/${_f}" ] || fail
done
grep -q 'rel="manifest"' "${WEB_DIST}/index.html" || fail
```

## Two things that will bite anyone re-deriving this

**Basic auth silently disqualifies the manifest.** The server runs with
`--basic_auth_user/--basic_auth_password`, and a manifest is fetched by the browser as
a *separate* request. With a plain `<link rel="manifest" href="manifest.json">` that
request goes out anonymously, comes back `401`, and the app is not installable — with
no console error worth noticing. Upstream's `index.html` therefore has
`crossorigin="use-credentials"`, and that attribute is load-bearing, not decoration.

**Secure context is a precondition, and it is about the browser's origin, not the
backend hop.** `selkies-core.js` aborts at startup with *"This application requires a
secure connection (HTTPS)"* unless `window.isSecureContext` is true, because the whole
websockets video path runs on WebCodecs (`VideoDecoder`), which is secure-context-only.
Serving the app over plain `http://host:8080` therefore fails long before PWA is in the
picture. TLS terminated at a reverse proxy satisfies it (the browser sees `https://`);
so does `http://localhost` through an SSH tunnel, which is the exception in the
secure-context spec.

`start_url` stays relative (`"."`) so an installed client relaunches into the subfolder
it was served from — an absolute `"/"` discards it behind a proxy that mounts the app
under a path.

## Verification

On a running host, with the correct bundle in place:

```
$ curl -s -u user:pass -o /dev/null -w '%{http_code} %{content_type}\n' http://127.0.0.1:8080/manifest.json
200 application/json
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/manifest.json   # no credentials
401
```

That `401` is the whole reason for `crossorigin="use-credentials"`. In the browser,
DevTools → Application → Manifest must list the icons without errors; a hard reload is
required because the manifest-less `index.html` caches.
