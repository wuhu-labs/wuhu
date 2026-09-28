import type { ReactElement } from 'react'
import { Tooltip as BaseTooltip } from '@base-ui/react/tooltip'

export function Tooltip({ label, kbd, children }: {
  label: string
  kbd?: string
  children: ReactElement
}) {
  return (
    <BaseTooltip.Provider delay={450}>
      <BaseTooltip.Root>
        <BaseTooltip.Trigger render={children} />
        <BaseTooltip.Portal>
          <BaseTooltip.Positioner side='bottom' sideOffset={8}>
            <BaseTooltip.Popup className='wui-tooltip'>
              {label}
              {kbd && <span className='wui-tooltip-kbd'>{kbd}</span>}
            </BaseTooltip.Popup>
          </BaseTooltip.Positioner>
        </BaseTooltip.Portal>
      </BaseTooltip.Root>
    </BaseTooltip.Provider>
  )
}
