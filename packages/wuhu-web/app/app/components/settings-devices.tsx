import { useEffect, useMemo, useState } from 'react'
import { inviteCountdown } from '~/lib/invite'
import { qrModules, qrSvgPath } from '~/lib/qr'
import { errorMessage } from '~/sdk/errors'
import {
  mintShareLogin,
  revokeInvite,
  type ShareLogin,
} from '~/sdk/share-login'

// Inviting a device and logging out act with this browser's key: without
// one (signOut null) the card only says so.
export function DevicesCard({ signOut }: { signOut: (() => void) | null }) {
  if (signOut === null) {
    return (
      <section className='wuhu-card wuhu-settings-card'>
        <p className='wuhu-muted'>
          This browser has no key of its own, so it can't invite a device.
        </p>
      </section>
    )
  }
  return <KeyDevicesCard signOut={signOut} />
}

function KeyDevicesCard({ signOut }: { signOut: () => void }) {
  const [invite, setInvite] = useState<ShareLogin | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [now, setNow] = useState(() => new Date())

  useEffect(() => {
    if (invite == null) return
    const tick = setInterval(() => setNow(new Date()), 1000)
    return () => clearInterval(tick)
  }, [invite])

  const mint = () => {
    setBusy(true)
    setError(null)
    setCopied(false)
    mintShareLogin()
      .then((minted) => {
        setInvite(minted)
        setNow(new Date())
      })
      .catch((failure: unknown) => setError(errorMessage(failure)))
      .finally(() => setBusy(false))
  }

  const revoke = () => {
    if (invite == null) return
    setBusy(true)
    setError(null)
    revokeInvite(invite.token)
      .then(() => setInvite(null))
      .catch((failure: unknown) => setError(errorMessage(failure)))
      .finally(() => setBusy(false))
  }

  return (
    <section className='wuhu-card wuhu-settings-card'>
      <p className='wuhu-muted'>
        Scan from the phone's Wuhu login page, or open the link. One-time,
        expires in 10 minutes.
      </p>
      {invite && (
        <div className='wuhu-invite'>
          <InviteCode url={invite.url} />
          <div className='wuhu-panel wuhu-invite-url'>
            <div className='wuhu-panel-code'>{invite.url}</div>
          </div>
          <div className='wuhu-invite-meta'>
            <span>{inviteCountdown(invite.expiresAt, now)}</span>
            <button
              type='button'
              className='wuhu-quiet-button'
              onClick={() => {
                void navigator.clipboard?.writeText(invite.url)
                setCopied(true)
              }}
            >
              {copied ? 'Copied' : 'Copy'}
            </button>
            <button
              type='button'
              className='wuhu-quiet-button'
              disabled={busy}
              onClick={revoke}
            >
              Revoke
            </button>
          </div>
        </div>
      )}
      {error && <p className='wuhu-alert'>{error}</p>}
      <div className='wuhu-form-actions'>
        <button
          type='button'
          className='wuhu-quiet-button wuhu-settings-logout'
          onClick={signOut}
        >
          Log out
        </button>
        <button
          type='button'
          className='wuhu-button'
          disabled={busy}
          onClick={mint}
        >
          Invite a device
        </button>
      </div>
    </section>
  )
}

const quietZone = 4

function InviteCode({ url }: { url: string }) {
  const { size, path } = useMemo(() => {
    const modules = qrModules(url)
    return { size: modules.length, path: qrSvgPath(modules) }
  }, [url])
  const span = size + quietZone * 2
  return (
    <svg
      className='wuhu-invite-qr'
      viewBox={`${-quietZone} ${-quietZone} ${span} ${span}`}
      shapeRendering='crispEdges'
      role='img'
      aria-label='Invite QR code'
    >
      <path d={path} fill='currentColor' />
    </svg>
  )
}
