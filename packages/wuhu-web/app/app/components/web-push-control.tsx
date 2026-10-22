import { useEffect, useState } from 'react'
import { errorMessage } from '~/sdk/errors'
import {
  currentWebPushState,
  disableWebPush,
  enableWebPush,
  type WebPushState,
} from '~/sdk/web-push'

const unavailable: Partial<Record<WebPushState['kind'], string>> = {
  unsupported: 'Notifications are unavailable in this browser.',
  'install-required': 'Install the app to get notifications.',
  blocked: 'Notifications are blocked in system settings.',
}

// Notifications for this browser: on or off, or why they cannot be.
export function WebPushControl() {
  const [state, setState] = useState<WebPushState>({ kind: 'working' })

  useEffect(() => {
    let active = true
    currentWebPushState().then(
      (next) => {
        if (active) setState(next)
      },
      (failure: unknown) => {
        if (active) setState({ kind: 'error', message: errorMessage(failure) })
      },
    )
    return () => {
      active = false
    }
  }, [])

  const notice = unavailable[state.kind]
  if (notice) return <p className='wuhu-muted'>{notice}</p>
  const enabled = state.kind === 'enabled'
  return (
    <div className='wuhu-form-actions'>
      {state.kind === 'error' && (
        <span className='wuhu-alert'>{state.message}</span>
      )}
      <button
        type='button'
        className='wuhu-button-secondary'
        disabled={state.kind === 'working'}
        onClick={() => {
          setState({ kind: 'working' })
          const operation = enabled ? disableWebPush() : enableWebPush()
          void operation.then(setState, (failure: unknown) => {
            setState({ kind: 'error', message: errorMessage(failure) })
          })
        }}
      >
        {state.kind === 'working'
          ? 'Checking notifications…'
          : enabled
          ? 'Turn off notifications'
          : 'Turn on notifications'}
      </button>
    </div>
  )
}
