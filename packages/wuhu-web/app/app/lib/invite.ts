import { enrollHash } from '~/lib/enroll-link'
import { screens } from '~/lib/links'

export function inviteUrl(
  origin: string,
  token: string,
  space: string,
): string {
  return `${origin}${screens.enroll}${enrollHash({ token, space })}`
}

export function inviteCountdown(expiresAt: number, now: Date): string {
  const seconds = Math.round(expiresAt - now.getTime() / 1000)
  if (seconds <= 0) return 'expired'
  if (seconds < 60) return `expires in ${seconds}s`
  return `expires in ${Math.ceil(seconds / 60)}m`
}
