import { sharedGroup } from './groups.ts'
import { placeGroup, screens, systemAddress, withoutGroup } from './links.ts'
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
  // Outside the SPA a group is its host, never the query.
  const group = placeGroup(search)
  const query = withoutGroup(search)
  const url = {
    host: group === sharedGroup ? host : `${group}.${host}`,
    destination,
    ...(query.length > 1 ? { query: query.slice(1) } : {}),
    ...(hash.length > 1 ? { fragment: hash.slice(1) } : {}),
  }
  return {
    https: formatSpaceURL(url, 'https'),
    wuhu: formatSpaceURL(url, 'wuhu'),
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
