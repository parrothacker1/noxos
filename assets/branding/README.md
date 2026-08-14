# NoxOS branding

Master logo assets, source of truth for both `noxos-app`'s launcher icon and `noxos-os`'s boot animation. Both of those repos vendor their own copy (Gradle/AOSP both need the asset physically present in-repo to build) — this is the canonical source if the mark ever changes.

## Mark

A hexagon (the VM isolation boundary — every untrusted payload runs inside one and gets destroyed after) around a crescent moon (*nox* = night). Navy `#0B1220` background, teal `#4FD1C5` mark — reads clearly down to launcher-icon size.

| File | Use |
|---|---|
| `logo-mark.svg` | Combined mark + background, square. General branding, README badges, boot animation source. |
| `ic_launcher_background.svg` | Background layer only, for Android adaptive icons. |
| `ic_launcher_foreground.svg` | Mark only, transparent background, sized to the adaptive-icon safe zone. |

## Where it's used

- `noxos-app/app/src/main/res/` — adaptive icon (`mipmap-anydpi-v26/`, vector drawables) + legacy PNG fallbacks (`mipmap-{m,h,x,xx,xxx}dpi/`) for API < 26.
- `noxos-os/branding/` — `generate-bootanimation.sh` turns `logo-mark.svg` into a fade-in `bootanimation.zip`. Not wired into any build target yet — no device tree exists to reference it from until P3/P4 (lightweight base) work starts.
