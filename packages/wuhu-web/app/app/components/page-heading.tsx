import { groupLabel } from '~/lib/groups'
import { useDirectory } from '~/lib/use-directory'

export function PageHeading(
  { title, group, className }: {
    title: string
    group: string
    className?: string
  },
) {
  const directory = useDirectory()
  return (
    <hgroup className={['wuhu-heading', className].filter(Boolean).join(' ')}>
      <h1 className='wuhu-title'>{title}</h1>
      <p className='wuhu-subtitle'>{groupLabel(group, directory)}</p>
    </hgroup>
  )
}
