import type { DevicePayload, DeviceRegisterInput } from '~/lib/contract.gen'
import { api } from './http'

export function deviceName(userAgent: string): string {
  const browser = /Edg\//.test(userAgent)
    ? 'Edge'
    : /Firefox\//.test(userAgent)
    ? 'Firefox'
    : /Chrome\//.test(userAgent)
    ? 'Chrome'
    : /Safari\//.test(userAgent)
    ? 'Safari'
    : 'A browser'
  const system = /iPhone/.test(userAgent)
    ? 'iOS'
    : /iPad/.test(userAgent)
    ? 'iPadOS'
    : /Android/.test(userAgent)
    ? 'Android'
    : /Mac OS X/.test(userAgent)
    ? 'macOS'
    : /Windows/.test(userAgent)
    ? 'Windows'
    : /Linux/.test(userAgent)
    ? 'Linux'
    : null
  return system == null ? browser : `${browser} on ${system}`
}

// The server keys a device by its key and the browser holds one key, so the
// device is this browser, every open tab shares it, and the key itself names
// the installation: it lives and dies with the enrollment.
export function registerDevice(key: string): Promise<DevicePayload> {
  const input: DeviceRegisterInput = {
    installation: key,
    kind: 'web',
    name: deviceName(navigator.userAgent),
  }
  return api('/v1/device', {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(input),
  })
}
