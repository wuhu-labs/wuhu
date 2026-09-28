import { useEffect } from 'react'
import { useLocation } from 'react-router'
import { type MenuAction, TopbarActions } from '@wuhu/ui'
import {
  isApplePlatform,
  shareLabel,
  shareLinks,
  sharePage,
  smartBannerContent,
} from '~/lib/share'

export function ShareActions({ menu = [] }: { menu?: MenuAction[] }) {
  const location = useLocation()
  const links = shareLinks(
    globalThis.location.origin,
    location.pathname,
    location.search,
    location.hash,
  )

  useEffect(() => {
    let banner = document.querySelector<HTMLMetaElement>(
      'meta[name="apple-itunes-app"]',
    )
    if (banner == null) {
      banner = document.createElement('meta')
      banner.name = 'apple-itunes-app'
      document.head.append(banner)
    }
    banner.content = smartBannerContent(links)
  }, [links?.wuhu])

  if (links == null) {
    return menu.length > 0 && <TopbarActions actions={[]} menu={menu} />
  }
  const share: MenuAction = {
    label: shareLabel(navigator),
    icon: 'share',
    onSelect: () => void sharePage(links.https, navigator),
  }
  const actions: MenuAction[] = isApplePlatform(navigator.userAgent)
    ? [{
      label: 'Open in app',
      icon: 'openApp',
      onSelect: () => globalThis.location.assign(links.wuhu),
    }]
    : []
  return <TopbarActions actions={actions} menu={[share, ...menu]} />
}
