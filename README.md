# Evidence — background press_key Return silently dropped on Chromium (macOS)

Artifacts for the trycua/cua issue "Chromium silently drops the background
press_key path that 0.34.x describes as Chromium-safe". Isolated Chrome
instance (own --user-data-dir), cua-driver 0.34.0, macOS 26.6.2, Chrome
155.0.8059.39. No user data is involved.

- `repro_chromium_background_key_drop.sh` + `srv/` — the repro (self-teed)
- `runs/v7mx/` — run 2 quoted in the issue: per-call raw JSON, screenshots,
  run_manifest.tsv, run_output.txt (literal capture)
- `runs/VGF3/a2_after_return.png` — run 1: the omnibox popup left open after
  the refused background Return (the state the delivered reset Return later
  committed against)

Raw file URLs: https://raw.githubusercontent.com/xronocode/cua/issue-evidence/chromium-key-drop/<path>
