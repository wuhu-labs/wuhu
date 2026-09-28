import { base64, signBytes } from './assertion'
import { enrolledDevice } from './auth'
import { api, post } from './http'
import { inviteUrl } from '~/lib/invite'
import type {
  EnrollRevokeInput,
  ShareLoginChallengeOutput,
  ShareLoginInput,
  ShareLoginOutput,
} from '~/lib/contract.gen'

export interface ShareLogin {
  url: string
  token: string
  expiresAt: number
}

const encoder = new TextEncoder()

export async function mintShareLogin(
  ttlSeconds = 600,
): Promise<ShareLogin> {
  const device = await enrolledDevice()
  if (device == null) throw new Error('this browser is not enrolled')
  const { challenge } = await api<ShareLoginChallengeOutput>(
    '/v1/enroll/share-login/challenge',
  )
  const signature = await signBytes(
    device,
    encoder.encode(`wuhu-share-login:${challenge}`),
  )
  const input: ShareLoginInput = {
    pubkey: device.label,
    challenge,
    signature: base64(signature),
    ttlSeconds,
  }
  const minted = await post<ShareLoginOutput>('/v1/enroll/share-login', input)
  return {
    url: inviteUrl(globalThis.location.origin, minted.token, minted.space),
    token: minted.token,
    expiresAt: minted.expiresAt,
  }
}

export async function revokeInvite(token: string): Promise<void> {
  const input: EnrollRevokeInput = { token }
  await post<Record<string, never>>('/v1/enroll/revoke', input)
}
