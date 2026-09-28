import { useEffect, useState } from 'react'
import { SidebarNote, SidebarRow } from '@wuhu/ui'
import { errorMessage } from '~/sdk/errors'
import {
  currentWebPushState,
  disableWebPush,
  enableWebPush,
  type WebPushState,
} from '~/sdk/web-push'

const unavailable: Partial<Record<WebPushState['kind'], string>> = {
  unsupported: 'Notifications unavailable',
  'install-required': 'Add to Home Screen for notifications',
  blocked: 'Notifications blocked in system settings',
}

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
  if (notice) return <SidebarNote>{notice}</SidebarNote>

  const enabled = state.kind === 'enabled'
  const working = state.kind === 'working'
  return (
    <>
      <SidebarRow
        quiet
        icon='message'
        label={working
          ? 'Checking notifications…'
          : enabled
          ? 'Notifications on'
          : 'Enable notifications'}
        status={enabled ? { tone: 'mint', label: 'on' } : undefined}
        onClick={working ? undefined : () => {
          setState({ kind: 'working' })
          const operation = enabled ? disableWebPush() : enableWebPush()
          void operation.then(setState, (failure: unknown) => {
            setState({ kind: 'error', message: errorMessage(failure) })
          })
        }}
      />
      {state.kind === 'error' && (
        <SidebarRow
          quiet
          icon='message'
          label='Notifications unavailable'
          title={state.message}
          status={{ tone: 'rose', label: 'unavailable' }}
        />
      )}
    </>
  )
}
