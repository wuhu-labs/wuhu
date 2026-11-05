import { generateImage, editImage } from 'wuhu:ai'
const gif = await generateImage('a fox waving', { destination: '/art/fox.gif', model: 'gpt-image-2.6-flare', frames: 2, frameMs: 120 })
const refusals = []
for (const invoke of [
  () => generateImage('fox', { destination: '/art/still.gif', model: 'gpt-image-2' }),
  () => editImage(['/reference.png'], 'fox', { destination: '/art/edit.gif', model: 'gpt-image-2.6-flare' }),
  () => generateImage('fox', { destination: '/art/still.png', model: 'gpt-image-2.6-flare', frames: 4 }),
  () => generateImage('fox', { destination: '/art/many.gif', model: 'gpt-image-2.6-flare', frames: 17 }),
  () => generateImage('fox', { destination: '/art/logo.svg' }),
]) {
  try { await invoke(); refusals.push('succeeded') }
  catch (error) { refusals.push(error.code) }
}
result({ gif, refusals })
