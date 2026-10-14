---
name: avatar
description: Give yourself a profile photo — generate 4 candidates in parallel from run_script with wuhu:ai, let the person who asked pick one, promote it to avatar.png; crop it when the pick looks small in the circle.
---

# Your profile photo

Your photo is `/_/sessions/<your id>/avatar.png`, a PNG of any size. Only you (and a human) can write your home. With no file, the app shows your initials. The app crops it to a circle inscribed in the square and renders it as small as 40 px, so a subject that fills about 60–70 % of the frame reads well; one that fills a third of it turns into a dot.

## Candidates

Four candidates come from one script (`timeout_seconds: 300`; one image takes 15–40 s and the four run at the same time). One look per prompt, square, a clear face or mark that still reads at 40 px, with empty space around the subject but not so much that it shrinks.

```js
import { generateImage } from 'wuhu:ai'

const home = `/_/sessions/${import.meta.session}/avatar-candidates`
const stamp = Date.now()
const prompts = [
  '…candidate 1…',
  '…candidate 2…',
  '…candidate 3…',
  '…candidate 4…',
]
const outcomes = await Promise.allSettled(
  prompts.map((prompt, i) =>
    generateImage(prompt, { destination: `${home}/${stamp}-${i + 1}.png` })
  ),
)
result(
  outcomes.map((
    o,
  ) => (o.status === 'fulfilled'
    ? o.value.path
    : `failed: ${o.reason.message}`)
  ),
)
```

`generateImage` never overwrites, so each round gets fresh names (the `stamp`). The script returns paths and sizes, never bytes; `read` a path to look at it. A failed prompt (a provider limit, a safety filter) fails only its own candidate; rerun just that one. `stop_script` cancels whatever is still generating and leaves no partial files.

## The pick

The person picks. The message is the candidates as numbered `wuhu:` links and the question "which number?", nothing else: no descriptions of your process, no provisional avatar set in the meantime.

## Promoting

`move` from `wuhu:space` puts the pick in place:

```js
import { move } from 'wuhu:space'

const home = `/_/sessions/${import.meta.session}`
await move(`${home}/avatar-candidates/<pick>.png`, `${home}/avatar.png`, {
  replace: true,
})
result('done')
```

To change it later, put a new file at the same path.

## Cropping

A pick that looks small in the circle is cropped, not regenerated: the person chose that image. A machine with Python/PIL (or ImageMagick) does it; the bytes travel through `run_script`, where `wuhu:space` reads and writes space files and `wuhu:machine` reads and writes machine files. The machine's `/tmp` is shared by every session, so the scratch folder carries your session id:

```js
import { readBytes, stat, writeBytes } from 'wuhu:space'
import { machine } from 'wuhu:machine'

const home = `/_/sessions/${import.meta.session}`
const tmp = `/tmp/avatar-${import.meta.session}`
const m = machine('devbox')
const { data } = await readBytes(`${home}/avatar-candidates/<pick>.png`)
await m.mkdir(tmp)
await m.write(`${tmp}/in.png`, data)
// crop a square around the non-background bounding box, padded by ~15 %, so the subject fills ~65 % of the frame
await m.exec(`python3 - <<'EOF'
from PIL import Image, ImageChops
im = Image.open("${tmp}/in.png").convert("RGB")
bg = Image.new("RGB", im.size, im.getpixel((0, 0)))
mask = ImageChops.difference(im, bg).convert("L").point(lambda p: 255 if p > 40 else 0)  # threshold: generated backgrounds are not flat
box = mask.getbbox()
cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
side = min(max(box[2] - box[0], box[3] - box[1]) * 1.3, *im.size)
l, t = max(0, int(cx - side / 2)), max(0, int(cy - side / 2))
im.crop((l, t, int(l + side), int(t + side))).save("${tmp}/out.png")
EOF`)
const out = await m.read(`${tmp}/out.png`)
const current = await stat(`${home}/avatar.png`).catch(() => null)
await writeBytes(`${home}/avatar.png`, out, { ifMatch: current?.token ?? null })
result('done')
```

The same two modules move any file between the space and a machine, in either direction; `exec` with `wuhu cat <path>` / `wuhu put <path> --force` is the shell equivalent. The reply after a crop is one line.
