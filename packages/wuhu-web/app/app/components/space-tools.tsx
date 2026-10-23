import { GlassButton, Glyph } from '@wuhu/ui'

export function SpaceTools({ settings, onSettings, onCreate }: {
  settings: boolean
  onSettings: () => void
  onCreate: () => void
}) {
  return (
    <>
      <GlassButton
        aria-label='Settings'
        title='Settings'
        aria-pressed={settings}
        solid={settings}
        onClick={onSettings}
      >
        <Glyph name='gear' w={18} h={18} />
      </GlassButton>
      {!settings && (
        <GlassButton
          aria-label='New agent'
          title='New agent'
          onClick={onCreate}
        >
          <Glyph name='plus' w={15} h={16} />
        </GlassButton>
      )}
    </>
  )
}
