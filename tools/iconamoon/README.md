# IconaMoon

[IconaMoon](https://github.com/dariushhpg1/IconaMoon) by Dariush Habibpour, CC BY 4.0 ([LICENSE](LICENSE)): Wuhu's one icon set, vendored once for web and native.

`svg/` holds every icon of the six styles (regular, light, thin, bold, fill, duotone) as a 24×24 `currentColor` SVG named like the icon, and `aliases.json` the 37 names that repeat another icon. Both come unchanged from `@iconify-json/iconamoon` 1.2.2 (`icons.json`: each icon's `body` inside a 24×24 `<svg>`).

`//tools/iconamoon:sprite` builds the web's `/_/iconamoon.svg` (one `<symbol>` per name) and `names.json`, the names a script's `icon` may use. Where the web lists licenses, credit Dariush Habibpour.

`deno run --allow-read --allow-write tools/iconamoon/apple.ts` regenerates CommonUI’s SVG template asset catalog. `WuhuIcon` draws these images on Apple platforms. The SVG template color is black; shapes and paths are unchanged. Credit: IconaMoon by Dariush Habibpour, CC BY 4.0.
