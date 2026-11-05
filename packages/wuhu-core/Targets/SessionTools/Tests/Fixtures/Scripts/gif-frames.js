import { inspectImage, renderFrames } from 'wuhu:ai'
const inspected = await inspectImage('/lights.gif')
const sheet = await renderFrames('/lights.gif', { destination: '/art/lights.png' })
const picked = await renderFrames('/lights.gif', { destination: '/art/picked.png', frames: [2, 0] })
const refusals = []
for (const invoke of [
  () => renderFrames('/lights.gif', { destination: '/art/lights.png' }),
  () => renderFrames('/lights.gif', { destination: '/art/sheet.gif' }),
  () => renderFrames('/still.png', { destination: '/art/still.png' }),
  () => renderFrames('/lights.gif', { destination: '/art/none.png', frames: 0 }),
  () => renderFrames('/lights.gif', { destination: '/art/none.png', frames: [1.5] }),
  () => renderFrames('/lights.gif', { destination: '/art/none.png', size: 3 }),
  () => renderFrames('/lights.gif'),
  () => inspectImage('/notes.txt'),
  () => inspectImage(),
]) {
  try { await invoke(); refusals.push('succeeded') }
  catch (error) { refusals.push(`${error.code}: ${error.message}`) }
}
result({ inspected, still: await inspectImage('/still.png'), sheet, picked, refusals })
