import { useEffect, useRef, useState } from 'react'
import { transcribe, transcriber } from '~/sdk/transcribe'
import { errorMessage } from '~/sdk/errors'

export type DictationPhase = 'off' | 'starting' | 'recording' | 'transcribing'

// The two containers the transcriber takes that browsers record: webm in
// Chrome and Firefox, mp4 in Safari. Firefox's default ogg is refused.
function recordingType(): string | undefined {
  if (
    typeof MediaRecorder === 'undefined' ||
    navigator.mediaDevices?.getUserMedia === undefined
  ) return undefined
  return ['audio/webm', 'audio/mp4'].find((type) =>
    MediaRecorder.isTypeSupported(type)
  )
}

// Whether this browser can dictate into this space: it records a type the
// transcriber takes, and the space has a transcriber. Asked once per space.
export function useDictationOffered(): boolean {
  const [offered, setOffered] = useState(false)
  useEffect(() => {
    if (recordingType() === undefined) return
    let cancelled = false
    transcriber().then(
      (info) => {
        if (!cancelled) setOffered(info.available)
      },
      () => {},
    )
    return () => {
      cancelled = true
    }
  }, [])
  return offered
}

// One tap records, the next transcribes and hands the text to `heard`; it
// never sends. Unmounting mid-recording discards the audio, while a
// transcription already under way still reaches the draft that started it.
export function useDictation(
  heard: (text: string) => void,
  failed: (reason: string) => void,
) {
  const [phase, setPhase] = useState<DictationPhase>('off')
  const recorder = useRef<MediaRecorder | null>(null)
  const mounted = useRef(true)

  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
      const active = recorder.current
      if (active === null) return
      active.ondataavailable = null
      active.onstop = null
      active.stop()
      for (const track of active.stream.getTracks()) track.stop()
    }
  }, [])

  const start = async () => {
    setPhase('starting')
    let stream: MediaStream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      setPhase('off')
      failed('Wuhu needs microphone access to dictate.')
      return
    }
    if (!mounted.current) {
      for (const track of stream.getTracks()) track.stop()
      return
    }
    const active = new MediaRecorder(stream, { mimeType: recordingType() })
    const chunks: Blob[] = []
    active.ondataavailable = (event) => chunks.push(event.data)
    active.onstop = () => {
      for (const track of stream.getTracks()) track.stop()
      recorder.current = null
      setPhase('transcribing')
      transcribe(new Blob(chunks, { type: active.mimeType }))
        .then(heard, (failure: unknown) => failed(errorMessage(failure)))
        .finally(() => setPhase('off'))
    }
    recorder.current = active
    active.start()
    setPhase('recording')
  }

  const toggle = () => {
    if (phase === 'off') void start()
    else if (phase === 'recording') recorder.current?.stop()
  }

  return { phase, toggle }
}
