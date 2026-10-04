import { generateImage, editImage, transcribe } from 'wuhu:ai'
import webSearch, { webSearch as namedSearch } from 'wuhu:web_search'
const sources = await namedSearch('synthetic moon', { count: 2 })
const generated = await generateImage('moon', { destination: '/art/generated.png' })
const edited = await editImage(['/reference.png'], 'blue moon', { destination: '/art/edited.png' })
const audio = await transcribe('/audio.wav', { timestamps: ['words', 'segments'], diarize: true })
result({ sameSearchExport: webSearch === namedSearch, provider: sources.provider, title: sources.sources[0].title, image: generated.path, edit: edited.path, transcript: audio.text, start: audio.words[0].start, speaker: audio.segments[0].speaker })
