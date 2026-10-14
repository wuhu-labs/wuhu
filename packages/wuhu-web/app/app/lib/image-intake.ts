const maxBytes = 3 * 1024 * 1024
const fittedEdges = [2048, 1280, 800]
const jpegQualities = [0.85, 0.6, 0.4]

function encode(
  canvas: HTMLCanvasElement,
  type: 'image/png' | 'image/jpeg',
  quality?: number,
): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob(
      (blob) => {
        if (blob === null) reject(new Error('The image could not be encoded.'))
        else resolve(blob)
      },
      type,
      quality,
    )
  })
}

function scaled(
  source: CanvasImageSource,
  width: number,
  height: number,
  edge: number,
): HTMLCanvasElement {
  const scale = Math.min(1, edge / Math.max(width, height))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(width * scale))
  canvas.height = Math.max(1, Math.round(height * scale))
  canvas.getContext('2d')!.drawImage(source, 0, 0, canvas.width, canvas.height)
  return canvas
}

export async function prepareAttachment(file: File): Promise<File> {
  if (/\.svg$/i.test(file.name) || file.type === 'image/svg+xml') return file
  const head = new Uint8Array(await file.slice(0, 12).arrayBuffer())
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
    .every((byte, index) => head[index] === byte)
  const jpeg = head[0] === 0xff && head[1] === 0xd8 && head[2] === 0xff
  if ((png || jpeg) && file.size <= maxBytes) return file
  const url = URL.createObjectURL(file)
  const image = new Image()
  image.src = url
  try {
    try {
      await image.decode()
    } catch {
      return file
    }
    // Freeze the decoded frame before asynchronous encoding advances animation.
    const frame = scaled(
      image,
      image.naturalWidth,
      image.naturalHeight,
      fittedEdges[0],
    )
    for (const edge of fittedEdges) {
      const canvas = edge === fittedEdges[0]
        ? frame
        : scaled(frame, image.naturalWidth, image.naturalHeight, edge)
      const png = await encode(canvas, 'image/png')
      if (png.size <= maxBytes) return converted(file, png, 'png')
      for (const quality of jpegQualities) {
        const jpeg = await encode(canvas, 'image/jpeg', quality)
        if (jpeg.size <= maxBytes) return converted(file, jpeg, 'jpg')
      }
    }
    throw new Error(`${file.name}: that image will not fit under 3 MB.`)
  } finally {
    URL.revokeObjectURL(url)
  }
}

function converted(original: File, blob: Blob, extension: string): File {
  const stem = original.name.replace(/\.[^.]+$/, '')
  return new File([blob], `${stem}.${extension}`, {
    type: blob.type,
    lastModified: original.lastModified,
  })
}
