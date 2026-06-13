---
title: useradd -m skips /etc/skel when home dir already exists (selkin: no .bashrc for desktop user)
date: 2026-06-13
tags: [devops, selkin, useradd, debian-image]
severity: low
---

## Problem
In the Selkies builder (`debian_qcow2-cloud-init-selkin.sh`) the desktop user
(`${DESKTOP_USER}`, default `user`) had no `.bashrc` / `.profile` / `.bash_logout`
in its home directory, while `root` did.

## Root Cause
The Selkies portable build is unpacked into `/home/${DESKTOP_USER}` early in the
build (`[SELKIE]` block) via `mkdir -p /home/${DESKTOP_USER}` — **before** the user
exists. Later the `[USER]` block runs `useradd -m`. `useradd -m` copies `/etc/skel`
contents into the home directory **only when it creates that directory**. Because
`/home/${DESKTOP_USER}` already existed, useradd treated it as ready and skipped the
skel copy — so no dotfiles landed.

## Solution
After `useradd`, explicitly seed skel files (idempotent, won't clobber):
`cp -n /etc/skel/.bashrc /etc/skel/.profile /etc/skel/.bash_logout /home/${DESKTOP_USER}/`
The existing `chown -R ${DESKTOP_USER}:${DESKTOP_USER} /home/${DESKTOP_USER}` at the
end of the `[USER]` block fixes ownership of the seeded files. Only the selkin builder
is affected — the cloud-init / no-cloud-init builders create no non-root user.

## References
- linux-debian/debian_qcow2-cloud-init-selkin.sh, `[USER]` block
