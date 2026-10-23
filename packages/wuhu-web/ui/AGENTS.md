# wuhu-ui

The web chrome (`packages/wuhu-web/app` composes it; Electron loads that app).
The design is hazel-mock at `cac7a9f`: numbers, icons and kit shapes are copied
from it, never redrawn by eye. Public surface = the `exports` map; keep it
small.

- `tokens.css`: tokens, backdrop, glass, shell layout and the sidebar kit. Light
  only. The Tailwind `@theme` palette stays for `content.css` and login.
- `glass.tsx`: the one glass base. It owns fill, border, shadow, blur, height
  and radius; callers only lay out what is inside. Retune the look in
  `--wui-glass-*`.
- `shell.tsx`: `AppShell` places every layer on the window. Page layouts are
  `scroll` (the only scroller, full height under the floating titlebar and
  composer), `framed` (one card that never scrolls) and `immersive` (under the
  whole window). `useShell()` gives the scroller and the insets, the composer's
  live height included. No edge clip, mask or fade anywhere.
- `kit.tsx`: cards and rows from the mock's `src/kit`, drawn at their authored
  317px width without zoom.
- Desktop widths only; no compact or touch layout.
