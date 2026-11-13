import type { PersonaMintOutput, ServerInfo } from '~/lib/contract.gen'
import { enrolledDevice, recordPrincipal } from './auth'
import { ApiError, errorDetail } from './errors'
import { api } from './http'

export interface Viewer {
  principal: string
  spaceId: string
}

// Who the server says this browser is. A key's persona is asked once and kept
// with the key. Without a key the browser asks unsigned: a server that seats
// unsigned requests as a person names it, and its refusal means nobody, never
// a sign-out.
export async function ownViewer(): Promise<Viewer | null> {
  const device = await enrolledDevice()
  if (device != null) {
    if (device.principal != null) {
      return { principal: device.principal, spaceId: device.spaceId }
    }
    const minted = await api<PersonaMintOutput>('/v1/persona', {
      method: 'POST',
    })
    await recordPrincipal(minted.persona).catch(() => undefined)
    return { principal: minted.persona, spaceId: device.spaceId }
  }
  const response = await fetch('/v1/persona', { method: 'POST' })
  if (response.status === 401) return null
  const text = await response.text()
  if (!response.ok) {
    throw new ApiError(response.status, errorDetail(response.status, text))
  }
  const { persona } = JSON.parse(text) as PersonaMintOutput
  const { space } = await (await fetch('/v1/server')).json() as ServerInfo
  if (space == null) throw new Error('the server names no space id')
  return { principal: persona, spaceId: space }
}
