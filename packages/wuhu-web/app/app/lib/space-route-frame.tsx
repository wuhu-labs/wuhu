import type { ComponentProps } from 'react'
import { AppShell } from '@wuhu/ui'
import { isEmbeddedHost } from './embedded.ts'

export function SpaceRouteFrame(props: ComponentProps<typeof AppShell>) {
  if (!isEmbeddedHost()) return <AppShell {...props} />
  return (
    <div className='wui-root' style={props.style}>
      <div className='wui-canvas'>
        <main className='wuhu-embedded-body'>{props.children}</main>
      </div>
    </div>
  )
}
