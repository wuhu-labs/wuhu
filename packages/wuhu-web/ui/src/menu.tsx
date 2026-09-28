import type { ReactElement } from 'react'
import { ContextMenu as BaseContextMenu } from '@base-ui/react/context-menu'
import { Menu as BaseMenu } from '@base-ui/react/menu'
import { Icon, type IconName } from './icons.tsx'

export interface MenuAction {
  label: string
  icon?: IconName
  danger?: boolean
  onSelect: () => void
}

function itemClass(action: MenuAction): string {
  return action.danger ? 'wui-menu-item wui-menu-item-danger' : 'wui-menu-item'
}

function itemBody(action: MenuAction) {
  return (
    <>
      {action.icon && (
        <span className='wui-menu-item-icon'>
          <Icon name={action.icon} />
        </span>
      )}
      {action.label}
    </>
  )
}

export function OverflowMenu(
  { actions, label }: { actions: MenuAction[]; label: string },
) {
  return (
    <BaseMenu.Root>
      <BaseMenu.Trigger className='wui-icon-button' aria-label={label}>
        <Icon name='more' />
      </BaseMenu.Trigger>
      <BaseMenu.Portal>
        <BaseMenu.Positioner
          className='wui-menu-positioner'
          align='end'
          sideOffset={6}
        >
          <BaseMenu.Popup className='wui-menu'>
            {actions.map((action) => (
              <BaseMenu.Item
                key={action.label}
                className={itemClass(action)}
                onClick={action.onSelect}
              >
                {itemBody(action)}
              </BaseMenu.Item>
            ))}
          </BaseMenu.Popup>
        </BaseMenu.Positioner>
      </BaseMenu.Portal>
    </BaseMenu.Root>
  )
}

interface PickerOption {
  id: string
  label: string
  selected: boolean
  onSelect: () => void
}

interface PickerSection {
  id: string
  label: string
  options: PickerOption[]
}

export function Picker(
  { eyebrow, title, label, sections }: {
    eyebrow?: string
    title: string
    label: string
    sections: PickerSection[]
  },
) {
  return (
    <BaseMenu.Root>
      <BaseMenu.Trigger className='wui-picker' aria-label={label}>
        <span className='wui-picker-heading'>
          {eyebrow && <span className='wui-picker-eyebrow'>{eyebrow}</span>}
          <span className='wui-picker-title'>{title}</span>
        </span>
        <Icon name='chevronDown' />
      </BaseMenu.Trigger>
      <BaseMenu.Portal>
        <BaseMenu.Positioner
          className='wui-menu-positioner'
          align='start'
          sideOffset={6}
        >
          <BaseMenu.Popup className='wui-menu'>
            {sections.map((section) => (
              <BaseMenu.Group key={section.id} className='wui-menu-group'>
                <BaseMenu.GroupLabel className='wui-menu-group-label'>
                  {section.label}
                </BaseMenu.GroupLabel>
                {section.options.map((option) => (
                  <BaseMenu.Item
                    key={option.id}
                    className='wui-menu-item'
                    onClick={option.onSelect}
                  >
                    <span className='wui-menu-item-icon wui-menu-item-check'>
                      {option.selected && <Icon name='check' />}
                    </span>
                    {option.label}
                  </BaseMenu.Item>
                ))}
              </BaseMenu.Group>
            ))}
          </BaseMenu.Popup>
        </BaseMenu.Positioner>
      </BaseMenu.Portal>
    </BaseMenu.Root>
  )
}

export function ContextMenu({ actions, children }: {
  actions: MenuAction[]
  children: ReactElement
}) {
  return (
    <BaseContextMenu.Root>
      <BaseContextMenu.Trigger render={children} />
      <BaseContextMenu.Portal>
        <BaseContextMenu.Positioner className='wui-menu-positioner'>
          <BaseContextMenu.Popup className='wui-menu'>
            {actions.map((action) => (
              <BaseContextMenu.Item
                key={action.label}
                className={itemClass(action)}
                onClick={action.onSelect}
              >
                {itemBody(action)}
              </BaseContextMenu.Item>
            ))}
          </BaseContextMenu.Popup>
        </BaseContextMenu.Positioner>
      </BaseContextMenu.Portal>
    </BaseContextMenu.Root>
  )
}
