---
name: avatar
description: Give yourself a profile photo — generate 4 candidates in parallel from run_script with wuhu:ai, let the person who asked pick one, promote it to avatar.png.
---

# Your profile photo

Your photo is `/_/sessions/<your id>/avatar.png`, a PNG of any size. Only you (and a human) can write your home. With no file, the app shows your initials. The app crops it to a circle, so leave margin around the face.

## 1. Generate 4 candidates in one script

Run this with `run_script` (`timeout_seconds: 300`; one image takes 15–40 s, and the 4 run at the same time). Write your own prompts: one look per prompt, square, a clear face or mark that still reads at 40 px, not cropped tight (ask for empty space around the subject).

```js
import { generateImage } from "wuhu:ai"

const home = `/_/sessions/${import.meta.session}/avatar-candidates`
const stamp = Date.now()
const prompts = [
  "…candidate 1…",
  "…candidate 2…",
  "…candidate 3…",
  "…candidate 4…",
]
const outcomes = await Promise.allSettled(
  prompts.map((prompt, i) => generateImage(prompt, { destination: `${home}/${stamp}-${i + 1}.png` })),
)
result(outcomes.map((o) => (o.status === "fulfilled" ? o.value.path : `failed: ${o.reason.message}`)))
```

- `generateImage` never overwrites, so each round gets fresh names (the `stamp`).
- The script gets paths and sizes only, never the image bytes. `read` a path to look at it yourself.
- A failed prompt (for example the provider's safety filter) fails only its own candidate; rerun just that one.
- `stop_script` cancels whatever is still generating and leaves no partial files.

## 2. Let the person who asked pick

Look at the 4 with `read`, drop any that are broken, then send them one message: the candidates as numbered `wuhu:` links, and ask for a number. Nothing else.

## 3. Promote the pick

Move the chosen candidate to `/_/sessions/<your id>/avatar.png` with `run_script`:

```js
import { move } from "wuhu:space"

const home = `/_/sessions/${import.meta.session}`
await move(`${home}/avatar-candidates/<pick>.png`, `${home}/avatar.png`, { replace: true })
result("done")
```

To change it later, put a new file at the same path.
