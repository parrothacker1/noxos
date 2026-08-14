# NoxOS

A lightweight, security-focused alternative mobile OS. B.Tech major project, solo, built with AI coding agents.

Fork of AOSP that isolates untrusted content (downloads, sideloaded APKs, flagged network payloads) inside disposable Microdroid VMs using Android's pKVM hypervisor, with a companion audit app that makes the isolation demonstrable instead of a black box.

## Repos

- [noxos-os](https://github.com/parrothacker1/noxos-os) — AOSP customization, build config, infra
- [noxos-payload](https://github.com/parrothacker1/noxos-payload) — isolated payload/parsers running inside the Microdroid pVM
- [noxos-app](https://github.com/parrothacker1/noxos-app) — host-side Android app: trigger/router, network monitor, audit UI
- [noxos-server](https://github.com/parrothacker1/noxos-server) — static OTA manifest, published via GitHub Actions to GitHub Pages

## Status

Literature survey and architecture done. All four repos scaffolded — build tooling, module skeletons, CI. No feature implementation yet. Next: Phase 1 — build environment + unmodified Cuttlefish boot.
