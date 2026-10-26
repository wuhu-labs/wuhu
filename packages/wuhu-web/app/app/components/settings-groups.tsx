import { ListCard, Row, Switch } from '@wuhu/ui'
import type { SidebarCatalog } from '~/lib/use-sidebar-catalog'

export function GroupSettings({
  catalog,
}: {
  catalog: SidebarCatalog
}) {
  const selected = catalog.selectedGroup
  return (
    <div className='wuhu-content wuhu-settings wuhu-group-settings'>
      <h1 className='wuhu-settings-title'>{selected?.label ?? 'Groups'}</h1>
      {catalog.error && (
        <p className='wuhu-alert' role='alert'>{catalog.error}</p>
      )}
      {catalog.groups === null && <p className='wuhu-muted'>Loading…</p>}
      {selected && (
        <>
          <ListCard title='Group'>
            <Row
              label='Visibility'
              trail={selected.open === null
                ? selected.metadata === 'loading' ? 'Loading…' : 'Unknown'
                : selected.open
                ? 'Open'
                : 'Private'}
            />
            <Row label='Your role' trail={selected.role} />
          </ListCard>
          <ListCard title='Sidebars'>
            {selected.loading && <p className='wuhu-muted'>Loading…</p>}
            {selected.sidebars.map((entry) => (
              <Row
                key={entry.path}
                label={entry.title}
                trail={
                  <Switch
                    aria-label={`${entry.title}: Show in sidebar`}
                    checked={entry.visible}
                    disabled={catalog.busy}
                    onChange={(event) =>
                      void catalog.setVisible(
                        { group: selected.id, path: entry.path },
                        event.target.checked,
                      )}
                  />
                }
              />
            ))}
            {!selected.loading && selected.sidebars.length === 0 &&
              <p className='wuhu-muted'>No sidebars yet.</p>}
          </ListCard>
        </>
      )}
      {catalog.groups?.length === 0 && (
        <p className='wuhu-muted'>No readable groups.</p>
      )}
    </div>
  )
}
