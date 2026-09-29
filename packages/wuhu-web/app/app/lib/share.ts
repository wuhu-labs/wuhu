import { sharedGroup } from './groups.ts'
import {
  placeGroup,
  screens,
  systemAddress,
  withGroup,
  withoutGroup,
} from './links.ts'
import { formatSpaceURL, spaceDestination, spaceHost } from './space-url.ts'

export interface ShareLinks {
  https: string
  wuhu: string
}

export function shareLinks(
  origin: string,
  pathname: string,
  search: string,
  hash: string,
): ShareLinks | null {
  if (isScreen(pathname)) return null
  const host = spaceHost(origin)
  const destination = spaceDestination(pathname)
  if (host == null || destination == null) return null
  // The https link is the SPA's own URL, its group in the query; the app's
  // wuhu link names the group as a host label.
  const group = placeGroup(search)
  const query = withoutGroup(search)
  const place = (host: string, query: string) => ({
    host,
    destination,
    ...(query.length > 1 ? { query: query.slice(1) } : {}),
    ...(hash.length > 1 ? { fragment: hash.slice(1) } : {}),
  })
  return {
    https: formatSpaceURL(place(host, withGroup(query, group)), 'https'),
    wuhu: formatSpaceURL(
      place(group === sharedGroup ? host : `${group}.${host}`, query),
      'wuhu',
    ),
  }
}

export interface ShareTarget {
  share?: (data: { url: string }) => Promise<void>
  clipboard?: { writeText: (text: string) => Promise<void> }
}

export function shareLabel(target: ShareTarget): string {
  return target.share == null ? 'Copy link' : 'Share'
}

export async function sharePage(
  url: string,
  target: ShareTarget,
): Promise<'shared' | 'copied' | 'dismissed'> {
  if (target.share != null) {
    try {
      await target.share({ url })
      return 'shared'
    } catch (error) {
      if ((error as { name?: string })?.name === 'AbortError') {
        return 'dismissed'
      }
    }
  }
  await target.clipboard?.writeText(url)
  return 'copied'
}

export function isApplePlatform(userAgent: string): boolean {
  return /Macintosh|iPhone|iPad|iPod/.test(userAgent)
}

export const appStoreID = '6807771419'

export function smartBannerContent(links: ShareLinks | null): string {
  return links == null
    ? `app-id=${appStoreID}`
    : `app-id=${appStoreID}, app-argument=${links.wuhu}`
}

function isScreen(pathname: string): boolean {
  return (Object.values(screens) as string[]).includes(pathname) ||
    systemAddress(pathname) != null
}
