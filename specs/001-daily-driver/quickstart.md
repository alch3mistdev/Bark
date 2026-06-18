# Bark — Quickstart

## Install (from a DMG)

```bash
scripts/make-dmg.sh      # builds Bark.app (release) + dist/Bark.dmg
open dist/Bark.dmg
```

1. In the mounted disk image, **drag Bark into Applications**.
2. Launch Bark from Applications. Because it's ad-hoc signed (not Developer-ID notarized), macOS
   Gatekeeper blocks the first open — **right-click Bark.app → Open → Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Bark.app
   ```
3. Bark appears in the **menu bar** (no Dock icon). A welcome window walks you through three
   permissions — grant each:
   - **Microphone** — capture your voice (audio stays on device)
   - **Accessibility** — type cleaned text into the focused app
   - **Input Monitoring** — detect the global push-to-talk hotkey

## Use

- **Hold `fn` (Globe)** and speak; release to insert the cleaned text into whatever app is focused.
- Pick a **Mode** from the menu bar: `Raw` · `Clean` · `Email` · `Message` · `Code / Commit` · `List`.
  `Raw`/`Clean` are instant; LLM modes rewrite then insert.
- **Settings** (menu → Settings): change language, rebind the hotkey, add custom modes, enable
  Launch-at-login, and turn on encrypted history.

## Enable the on-device LLM rewrite (optional)

The default build uses the instant deterministic cleaner for every mode. To turn on the Qwen3-4B
rewrite for the LLM modes:

```bash
cp Package-mlx.swift Package.swift
scripts/make-dmg.sh        # first build compiles MLX/Metal — takes a while
```

The model (~2.5–3 GB) downloads from Hugging Face on first use, then runs fully offline. Revert with
`git checkout Package.swift`.

## Build & test from source

```bash
swift build                 # offline, zero third-party deps
swift test                  # 72 tests
```

## Privacy

Fully offline by default — no network at runtime except the one-time macOS speech-asset install.
History is off by default and encrypted (AES-256-GCM) when enabled; turning it off purges it. See
`docs/SECURITY.md` for the full threat model and honest limitations (L-1…L-6).

## Distribute to others (Developer ID + notarization)

```bash
scripts/make-app.sh "Developer ID Application: Your Name (TEAMID)"
xcrun notarytool submit dist/Bark.dmg --apple-id you@example.com --team-id TEAMID --wait
xcrun stapler staple dist/Bark.app
```

## Troubleshooting

- **Hotkey does nothing** → grant Input Monitoring (Settings → Permissions), or use the menu's
  Start button.
- **Text isn't typed** → grant Accessibility; Bark falls back to copying to the clipboard otherwise.
- **"Bark is damaged / can't be opened"** → the quarantine bit; run the `xattr` command above.
- **Dictation stopped working after the first time** → fixed (engine session is rebuilt per dictation);
  rebuild from latest source.
