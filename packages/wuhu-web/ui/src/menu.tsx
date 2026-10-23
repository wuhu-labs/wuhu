import type { ReactNode } from 'react'
import { Menu } from '@base-ui/react/menu'
import { Glass, GlassButton } from './glass.tsx'
import { Icon } from './icons.tsx'

export interface MenuItem {
  label: string
  onSelect: () => void
  disabled?: boolean
  selected?: boolean
}

export function GlassMenu(
  { label, lead, children, sections, placement = 'below' }: {
    label: string
    lead?: ReactNode
    children: ReactNode
    sections: MenuItem[][]
    placement?: 'below' | 'above'
  },
) {
  return (
    <Menu.Root>
      <Menu.Trigger
        render={
          <GlassButton
            circle={false}
            className={lead
              ? 'wui-menu-trigger wui-pill wui-pill-lead'
              : 'wui-menu-trigger wui-pill'}
          />
        }
        aria-label={label}
      >
        {lead}
        <span>{children}</span>
        <Icon name='arrow-down-2' size={14} />
      </Menu.Trigger>
      <Menu.Portal>
        <Menu.Positioner
          side={placement === 'above' ? 'top' : 'bottom'}
          align='start'
          sideOffset={8}
          className='wui-menu-positioner'
        >
          <Menu.Popup
            render={<Glass className='wui-menu' />}
            aria-label={label}
          >
            {sections.map((section, index) => (
              <Menu.Group key={index}>
                {index > 0 && <Menu.Separator />}
                <Menu.RadioGroup
                  value={String(section.findIndex((item) => item.selected))}
                >
                  {section.map((item, itemIndex) =>
                    item.selected === undefined
                      ? (
                        <Menu.Item
                          key={itemIndex}
                          disabled={item.disabled}
                          onClick={item.onSelect}
                        >
                          {item.label}
                        </Menu.Item>
                      )
                      : (
                        <Menu.RadioItem
                          closeOnClick
                          key={itemIndex}
                          value={String(itemIndex)}
                          disabled={item.disabled}
                          onClick={item.onSelect}
                        >
                          {item.label}
                          <Menu.RadioItemIndicator>✓</Menu.RadioItemIndicator>
                        </Menu.RadioItem>
                      )
                  )}
                </Menu.RadioGroup>
              </Menu.Group>
            ))}
          </Menu.Popup>
        </Menu.Positioner>
      </Menu.Portal>
    </Menu.Root>
  )
}
