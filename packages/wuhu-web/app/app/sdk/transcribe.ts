import { api } from './http'
import { requireAISharing } from '~/lib/ai-sharing'
import type { TranscriberInfo, TranscriptionOutput } from '~/lib/contract.gen'

export function transcriber(): Promise<TranscriberInfo> {
  return api('/v1/transcribe')
}

export async function transcribe(audio: Blob): Promise<string> {
  await requireAISharing()
  const output = await api<TranscriptionOutput>('/v1/transcribe', {
    method: 'POST',
    headers: { 'content-type': audio.type },
    body: audio,
  })
  return output.text
}
