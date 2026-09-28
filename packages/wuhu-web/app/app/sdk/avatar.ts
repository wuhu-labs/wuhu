import { authorizedRequest } from './http'

const edge = 128

export function avatarPath(principal: string): string {
  return `/users/${principal}/avatar.png`
}

export function sessionAvatarPath(session: string): string {
  return `/_/sessions/${session}/avatar.png`
}

const sessionAvatar = /^\/_\/sessions\/([^/]+)\/avatar\.png$/

export function sessionOfAvatarPath(path: string): string | null {
  return sessionAvatar.exec(path)?.[1] ?? null
}

async function resample(file: File): Promise<Blob> {
  const source = await createImageBitmap(file)
  try {
    const canvas = document.createElement('canvas')
    canvas.width = edge
    canvas.height = edge
    const context = canvas.getContext('2d')
    if (context == null) throw new Error('no 2d canvas context')
    const scale = Math.max(edge / source.width, edge / source.height)
    const width = source.width * scale
    const height = source.height * scale
    context.drawImage(
      source,
      (edge - width) / 2,
      (edge - height) / 2,
      width,
      height,
    )
    const png = await new Promise<Blob | null>((resolve) =>
      canvas.toBlob(resolve, 'image/png')
    )
    if (png == null) throw new Error('could not encode the picked image')
    return png
  } finally {
    source.close()
  }
}

export async function uploadAvatar(
  principal: string,
  file: File,
): Promise<void> {
  await authorizedRequest(`/v1/f${avatarPath(principal)}`, {
    method: 'PUT',
    headers: { 'content-type': 'image/png' },
    body: await resample(file),
  })
}
