import { useState } from 'react'
import { Link, useNavigate } from 'react-router'
import { isEmbeddedHost } from '~/lib/embedded'
import { parseEnrollFragment } from '~/lib/enroll-link'
import { screens } from '~/lib/links'
import { enroll } from '~/sdk/auth'
import { sharedGroup } from '~/lib/groups'
import { SpaceServer } from '~/sdk/client'

export function meta() {
  return [{ title: 'Enroll — Wuhu' }]
}

export default function Enroll() {
  const navigate = useNavigate()
  const [link] = useState(() => parseEnrollFragment(location.hash))
  const [state, setState] = useState<
    { phase: 'confirm' } | { phase: 'working' } | {
      phase: 'failed'
      message: string
    }
  >({ phase: 'confirm' })

  const confirm = async () => {
    if (link == null) return
    setState({ phase: 'working' })
    try {
      await enroll(link.token, link.space)
    } catch (failure) {
      setState({
        phase: 'failed',
        message: failure instanceof Error ? failure.message : String(failure),
      })
      return
    }
    // Enrollment succeeded and the token is spent; priming the content origin
    // is best-effort and must not surface as a "failed" retry prompt.
    await new SpaceServer().client(sharedGroup).contentOrigin().catch(() =>
      undefined
    )
    await navigate('/', { replace: true })
  }

  return (
    <div className='wui-root'>
      <div className='wui-canvas'>
        <main
          className={`${
            isEmbeddedHost() ? 'wuhu-embedded-body' : 'wuhu-standalone'
          } flex items-center justify-center`}
        >
          <div className='wuhu-card w-full max-w-sm'>
            <h1 className='wuhu-dialog-title'>Enroll this browser?</h1>
            {link == null
              ? (
                <p className='wuhu-muted mt-2'>
                  This enroll link is incomplete (missing its token or space
                  id). Mint a fresh one on an enrolled device with{' '}
                  <code>wuhu share-login</code>, or{' '}
                  <Link to={screens.login}>paste a link or QR photo</Link>.
                </p>
              )
              : (
                <>
                  <p className='wuhu-muted mt-2'>
                    A signing key is created in this browser and enrolled as a
                    device of this space. The one-time link is consumed.
                  </p>
                  <button
                    type='button'
                    disabled={state.phase === 'working'}
                    onClick={() => void confirm()}
                    className='wuhu-button wuhu-button-block mt-4'
                  >
                    {state.phase === 'working' ? 'Enrolling…' : 'Enroll'}
                  </button>
                  {state.phase === 'failed' && (
                    <p className='wuhu-alert mt-3'>{state.message}</p>
                  )}
                </>
              )}
          </div>
        </main>
      </div>
    </div>
  )
}
