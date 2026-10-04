---
name: image
description: Generate and prompt-edit PNG images using configured OpenAI, Qwen or zero-setup Codex capabilities, with private references and create-only outputs.
---

# Images

```js
import { generateImage, editImage } from 'wuhu:ai'
const generated = await generateImage('a lunar garden', { destination: '/art/garden.png' })
const edited = await editImage(['/art/garden.png'], 'make the sky blue', { destination: '/art/blue-garden.png' })
result({ generated, edited })
```

Both calls return `{ path, mimeType: 'image/png', bytes, width, height }`, not pixels/base64. Options are `{ destination, provider?, model?, quality?, size? }`. Sizes: `1024x1024`, `1536x1024`, `1024x1536`; default square. Quality: `draft`, `standard`, `fine`, `ultra`. Qwen maps these exactly to `z-image-turbo`, `qwen-image-3.0`, `qwen-image-3.0-pro`, `wan2.7-image-pro`. Draft cannot edit. Other providers expose draft/standard/fine; ultra fails honestly rather than pretending fine is ultra. Do not combine Qwen `model` and `quality` overrides. No masks, bboxes, strength, regional or streaming options in v1.

References must be private PNG paths in your group, a readable group's `wuhu://<group>.localspace/...`, or an authorized `machines://<name-or-id>/...` file. No public URL or caller staging. At most five references; Qwen 3.0 and dedicated editors accept three and at most 10 MiB per reference. Other references are at most 25 MiB. The server reads bytes and talks to the provider internally; provider result downloads never receive bearer credentials.

Outputs are create-only: an existing destination, system path or another session's home is refused before provider spending. Space writes are atomic create-only; machine writes retain the existing stat/write guards and claims within a script run, not a cross-process atomic guarantee. Up to four image calls in one script run concurrently. Cancellation is propagated and failed calls do not write. `generate_image` uses the same resolver and supports the same optional provider/model/quality/size fields.

`/capabilities.json` selects `image.active`; absent capability configuration synthesizes Codex through the existing ChatGPT login. Explicit missing/broken provider or key never silently falls back. `CapabilityError` has `code/message/hint`; unsupported editing/tier requests use `unsupported_feature`. Retry transient provider failures or deliberately select another configured provider. Credentials live in the native provider store, never script secrets.

CLI: `wuhu image 'a lunar garden' --destination ./garden.png [--provider qwen] [--quality standard]`; editing adds one or more `--image ./reference.png`. CLI local output is created exclusively and never overwritten. The CLI uploads bytes privately to the authenticated server; it does not publish references.
