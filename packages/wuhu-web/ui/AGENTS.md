# wuhu-ui

React component library for the Wuhu app chrome, shadcn-style: wuhu-ui owns
primitives and tokens, consumers compose them, `packages/wuhu-web/lab` is the
living visual documentation. Public surface = the `exports` map; keep it small.

## Decision log

- **2026-08-12 · Compact chrome is a navigation push, not an overlay.** The
  sidebar covers the whole viewport (opaque `--color-paper`, safe-area padded)
  while `.wui-stage` — canvas, topbar and composer, wrapped so one transform
  moves them together — parallaxes 33% right, UINavigationController-style. The
  scrim is gone (nothing to scrim under a full cover), the `layoutId` morph is
  wide-only, and the dismiss glyph is an xmark. A cover cannot use material: the
  pushed stage is its own backdrop root, so `backdrop-filter` blurs nothing and
  translucency shows unblurred content straight through. The open control moved
  into `Topbar` as an in-flow leading button, deleting the compact
  `padding-left: calc(52px + safe-left)` that existed only to clear the floating
  chip. `TopbarActions` now takes `actions: MenuAction[]` and picks its own
  presentation — icon row when wide, one overflow menu when compact and there is
  more than one action; `TopbarIconButton` left the public surface with it.
  Kinds a filename already carries earn no pill: only `Table`, `Directory` and
  the session `Direct`/`Channel` remain.

- **2026-08-03 · Adopted by the product SPA** (`packages/wuhu-web/app`), which
  forced three things the study never had to carry:
  - **Every ink value is a token.** `--wui-solid`/`--wui-on-solid`,
    `--wui-hover`/`--wui-selected`/`--wui-field`, `--wui-veil`,
    `--wui-hairline`, `--wui-glow`, `--wui-noise`. A dark scheme is a
    `prefers-color-scheme` block that reassigns them; no component knows.
  - **Compact (`max-width: 63.999rem`) is a real mode.** The sidebar leaves the
    layout, opens collapsed, and `wui-mode-focus` there means "sidebar
    dismissed", not "chrome dismissed" — the topbar and composer stay, since on
    a phone they are the only navigation and input left.
  - **Chrome respects the viewport it is given.** Every fixed edge is
    `env(safe-area-inset-*)`-aware, and `--wui-keyboard-inset` (set by the app
    from `visualViewport`) lifts the composer off a software keyboard.
    `AppShell` also publishes its scroll container as `useChrome().canvas`: the
    canvas is the only scroller, so a transcript pins itself to the bottom by
    driving it rather than nesting a scroller of its own. `ComposerZone` takes
    the input row as `children` — wuhu-ui owns the island and the chip, the
    consumer owns sending.

- **2026-07-17 · Animation system locked: Motion** (`motion` npm package,
  motion.dev). Three tiers, each with a home:
  - CSS transitions — micro-states only: hover, color, the topbar veil.
  - Motion — everything compositional: chrome mode changes, shared-element
    morphs (`layoutId`), enter/exit symmetry (`AnimatePresence`), springs.
  - View Transitions API — reserved for router-level page swaps; not used yet.
    SwiftUI mapping for future work: `matchedGeometryEffect` → `layoutId`,
    `.transition` → `AnimatePresence` initial/animate/exit, `.geometryGroup()` →
    layoutId crossfade, springs retarget on interruption like SwiftUI. AppShell
    owns morph containers (keyed, explicit enter/exit); consumer-provided nodes
    are never direct AnimatePresence children (keyless children leak).
- **2026-07-17 · Chrome doctrine ratified.** Material only where layers meet.
  The composer is the primary island; thread-peek keeps full material; topbar is
  ink on canvas with a permanent edge-to-edge veil (never scroll-triggered);
  sidebar minimizes into a persistent glass restore button (macOS-style genie).
  Rail mode is dead: `ChromeMode = "full" | "focus"`. Paper glass beat an
  ink-tinted A/B; material tokens stay warm white.
- **2026-07-17 · Shortcuts.** `⌘\` toggles sidebar/immersive (Notion
  convention), Esc exits focus, left-edge hover peeks the sidebar after 500ms.
- **2026-07-17 · Base UI entered** via its designated trigger (first popover
  need: the ⌘\ tooltip). Package is `@base-ui/react` — the old
  `@base-ui-components/react` name is deprecated at 1.0.0-rc.0; do not use it.
  `Tooltip` (src/tooltip.tsx) is the pattern for wrapping Base UI parts: wuhu-ui
  exports one styled component, Base UI stays an implementation detail, chip
  styling + `data-starting-style`/`data-ending-style` CSS transitions in
  tokens.css (tooltips are micro-states — CSS tier, not Motion).
- **2026-07-17 · Morph content rule.** Children of a `layoutId` element distort
  during projection; give them `layout` for scale-correction plus a delayed
  fade-in past the spring's violent phase (see the restore glyph). Custom
  tooltips replace native `title` on chrome controls; keep `aria-label`.
- **Dependencies.** `react`/`react-dom` are peers; `motion` and `@base-ui/react`
  are real dependencies. Add further Base UI parts only as concrete components
  need them.

## Verification caveat

Animations are frozen under safaridriver (Safari MCP): CSS transitions, WAAPI,
and Motion's projection all freeze mid-flight, so automated screenshots and DOM
probes cannot judge motion or AnimatePresence unmounts. Judge motion in a
non-automated browser; automate only structure and end states.
