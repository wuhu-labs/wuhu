import { generateImage, editImage, transcribe } from 'wuhu:ai'
import { webSearch } from 'wuhu:web_search'
const errors = []
for (const invoke of [
  () => webSearch('moon'),
  () => generateImage('moon', { destination: '/art/a.png' }),
  () => transcribe('/audio.wav'),
  () => editImage([], 'moon', { destination: '/art/b.png' }),
  () => generateImage('moon', { destination: '/art/c.png', mask: '/reference.png' }),
]) {
  try { await invoke() }
  catch (error) { errors.push({ code: error.code, hint: typeof error.hint, name: error.name }) }
}
result(errors)
