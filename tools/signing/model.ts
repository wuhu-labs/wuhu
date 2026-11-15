export type JSONValue =
  | string
  | number
  | boolean
  | null
  | JSONValue[]
  | { [key: string]: JSONValue }

export type NativePlatform =
  | 'ios'
  | 'visionos'
  | 'watchos'
  | 'tvos'
  | 'macos'
export type ProfileFamily = 'IOS' | 'MAC_OS' | 'TV_OS'
export type PortalDeviceClass =
  | 'IPHONE'
  | 'IPAD'
  | 'IPOD'
  | 'APPLE_VISION_PRO'
  | 'APPLE_WATCH'
  | 'APPLE_TV'
  | 'MAC'
export type Variant = 'Dev' | 'Store' | 'Direct'

export interface SigningDeviceConfig {
  readonly platform: NativePlatform
  readonly udid: string
}

export interface SigningConfig {
  readonly team: string
  readonly previewNamespace: string
  readonly previewMacDevices?: readonly string[]
  readonly renewal: string
  readonly certificates: readonly {
    readonly id: string
    readonly kind: 'development' | 'distribution' | 'developer-id'
  }[]
  readonly devices: Readonly<Record<string, SigningDeviceConfig>>
}

export interface SigningBundle {
  readonly displayName: string
  readonly identifier: string
  readonly nativePlatform: NativePlatform
  readonly profileFamily: ProfileFamily
  readonly compatibleDeviceClasses: ReadonlySet<PortalDeviceClass>
  readonly entitlements: Readonly<Record<string, JSONValue>>
  readonly releaseEntitlements: Readonly<Record<string, JSONValue>>
  readonly appRecordRequired: boolean
  readonly wildcard: boolean
}

export interface SigningProfile {
  readonly bundle: SigningBundle
  readonly variant: Variant
  readonly name: string
  readonly profileType: string
  readonly entitlements: Readonly<Record<string, JSONValue>>
}

export interface SigningDeclarations {
  readonly config: SigningConfig
  readonly profiles: readonly SigningProfile[]
}

export interface ProfileTarget {
  readonly bundleID: string
  readonly platform: string
  readonly distribution?: 'store' | 'direct'
  readonly devIdentity?: { readonly bundleID: string }
}

export function profileSelection(
  target: ProfileTarget,
  variant: 'dev' | 'store',
  hmr = false,
  previewNamespace = 'tech.lakeridge.previews',
):
  | { identifier: string; platform: NativePlatform; variant: Variant }
  | undefined {
  const platform = target.platform.toLowerCase() as NativePlatform
  if (!['ios', 'visionos', 'watchos', 'tvos', 'macos'].includes(platform)) {
    return
  }
  const preview = target.bundleID.startsWith(`${previewNamespace}.`)
  if (preview) {
    if (variant !== 'dev') return
    if (platform === 'macos' && !hmr) return
    if (platform === 'visionos' && !hmr) return
    return {
      identifier: `${previewNamespace}.*`,
      platform: platform === 'visionos' ? 'ios' : platform,
      variant: 'Dev',
    }
  }
  return {
    identifier: variant === 'dev' && target.devIdentity
      ? target.devIdentity.bundleID
      : target.bundleID,
    platform,
    variant: target.distribution === 'direct'
      ? 'Direct'
      : variant === 'dev'
      ? 'Dev'
      : 'Store',
  }
}
