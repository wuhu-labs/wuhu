import { prepareZXingModule, readBarcodes } from 'zxing-wasm/reader'
import wasmURL from 'zxing-wasm/reader/zxing_reader.wasm?url'
import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router'
import { enrollHash, parsePastedEnrollLink } from '~/lib/enroll-link'
import { screens } from '~/lib/links'

export function meta() {
  return [{ title: 'Log in — Wuhu' }]
}

// The CSP forbids external hosts, so the decoder's wasm ships as our own
// bundled asset instead of the package's CDN default.
prepareZXingModule({
  overrides: {
    locateFile: (path: string) => (path.endsWith('.wasm') ? wasmURL : path),
  },
})

const readerOptions = {
  formats: ['QRCode' as const],
  tryHarder: true,
  tryInvert: true,
  tryRotate: true,
}

class DecoderUnavailable extends Error {}

async function decodeQRImage(file: File): Promise<string | null> {
  const bitmap = await createImageBitmap(file)
  try {
    // Full resolution first; a phone photo of a screen often needs a
    // downscale pass instead, which softens moiré before the decoder sees it.
    const widths = [
      ...new Set(
        [bitmap.width, 1600, 800].map((width) => Math.min(width, bitmap.width)),
      ),
    ]
    for (const width of widths) {
      const scale = width / bitmap.width
      const canvas = document.createElement('canvas')
      canvas.width = Math.max(1, width)
      canvas.height = Math.max(1, Math.round(bitmap.height * scale))
      const context = canvas.getContext('2d')
      if (context == null) return null
      context.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
      const image = context.getImageData(0, 0, canvas.width, canvas.height)
      const results = await readBarcodes(image, readerOptions).catch(
        (failure: unknown) => {
          throw new DecoderUnavailable(String(failure))
        },
      )
      const text = results[0]?.text
      if (text) return text
    }
    return null
  } finally {
    bitmap.close()
  }
}

export default function Login() {
  const navigate = useNavigate()
  const [pasted, setPasted] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [dragging, setDragging] = useState(false)
  const [scanning, setScanning] = useState(false)
  const picker = useRef<HTMLInputElement>(null)
  const video = useRef<HTMLVideoElement>(null)
  const stopStream = useRef<(() => void) | null>(null)
  const startingScan = useRef(false)

  useEffect(() => () => stopStream.current?.(), [])

  const [decoded, setDecoded] = useState<
    { hash: string; display: string } | null
  >(null)

  // A decoded code is shown for inspection and continues only on an explicit
  // click — a scanned QR is untrusted input, not a navigation command. The
  // pasted path navigates directly: its Continue button is the manual step.
  const accept = (text: string, source: string): boolean => {
    const link = parsePastedEnrollLink(text)
    if (link == null) {
      setError(`${source} is not a wuhu invite link.`)
      return false
    }
    stopStream.current?.()
    setScanning(false)
    setError(null)
    setDecoded({ hash: enrollHash(link), display: text.trim() })
    return true
  }

  const acceptPasted = () => {
    const link = parsePastedEnrollLink(pasted)
    if (link == null) {
      setError('That is not a wuhu invite link.')
      return
    }
    void navigate(`${screens.enroll}${enrollHash(link)}`)
  }

  const acceptImage = (file: File | undefined) => {
    if (file == null) return
    setError(null)
    setDecoded(null)
    decodeQRImage(file).then(
      (text) => {
        if (text == null) {
          setError(
            'No QR code found in that image. Fill the frame with the code, straight on, without glare.',
          )
        } else accept(text, 'That QR code')
      },
      (failure: unknown) =>
        setError(
          failure instanceof DecoderUnavailable
            ? 'The QR decoder failed to load. Reload and try again.'
            : 'Could not read that file as an image.',
        ),
    )
  }

  const stopScan = () => {
    stopStream.current?.()
    stopStream.current = null
    setScanning(false)
  }

  const startScan = async () => {
    // Synchronous guard: a second tap while getUserMedia is pending would
    // overwrite stopStream and orphan the first stream's tracks and loop.
    if (startingScan.current || stopStream.current != null) return
    startingScan.current = true
    setError(null)
    setDecoded(null)
    let stream: MediaStream
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment' },
      })
    } catch {
      setError('Camera unavailable or permission denied.')
      return
    } finally {
      startingScan.current = false
    }
    const element = video.current
    if (element == null) {
      for (const track of stream.getTracks()) track.stop()
      return
    }
    let cancelled = false
    stopStream.current = () => {
      cancelled = true
      for (const track of stream.getTracks()) track.stop()
      element.srcObject = null
    }
    element.srcObject = stream
    setScanning(true)
    try {
      await element.play()
    } catch {
      stopScan()
      setError('Camera preview failed to start.')
      return
    }
    const canvas = document.createElement('canvas')
    let decoderFailures = 0
    const tick = async () => {
      if (cancelled) return
      if (element.videoWidth > 0) {
        canvas.width = element.videoWidth
        canvas.height = element.videoHeight
        const context = canvas.getContext('2d')
        if (context != null) {
          context.drawImage(element, 0, 0)
          const image = context.getImageData(0, 0, canvas.width, canvas.height)
          const results = await readBarcodes(image, readerOptions).catch(
            () => null,
          )
          if (results == null) {
            decoderFailures += 1
            if (decoderFailures >= 10) {
              stopScan()
              setError('The QR decoder failed to load. Reload and try again.')
              return
            }
          } else {
            decoderFailures = 0
          }
          const text = results?.[0]?.text
          if (text != null && !cancelled) {
            const link = parsePastedEnrollLink(text)
            if (link != null) {
              stopScan()
              setError(null)
              setDecoded({ hash: enrollHash(link), display: text.trim() })
              return
            }
            setError('That QR code is not a wuhu invite link.')
          }
        }
      }
      globalThis.setTimeout(() => void tick(), 200)
    }
    void tick()
  }

  return (
    <div className='wui-root'>
      <div className='wui-canvas'>
        <main className='wuhu-standalone flex items-center justify-center'>
          <div className='wuhu-card w-full max-w-sm'>
            <h1 className='wuhu-dialog-title'>Log in</h1>
            <p className='wuhu-muted mt-2'>
              This space admits enrolled devices only. On an enrolled device,
              mint a one-time invite with{' '}
              <code>wuhu share-login</code>, then bring it here.
            </p>
            <label className='wuhu-field wuhu-field-mono mt-5'>
              <span>Paste the invite link</span>
              <input
                placeholder='https://…/_/enroll#token=…'
                value={pasted}
                onChange={(event) => setPasted(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' && pasted.trim() !== '') {
                    acceptPasted()
                  }
                }}
              />
            </label>
            <button
              type='button'
              disabled={pasted.trim() === ''}
              onClick={acceptPasted}
              className='wuhu-button wuhu-button-block mt-3'
            >
              Continue
            </button>
            {decoded && (
              <div data-wuhu-decoded-invite className='wuhu-panel mt-5'>
                <p className='wuhu-muted'>
                  Decoded invite — check it points where you expect
                </p>
                <p className='wuhu-panel-code mt-1'>{decoded.display}</p>
                <div className='mt-3 flex gap-2'>
                  <button
                    type='button'
                    onClick={() =>
                      void navigate(`${screens.enroll}${decoded.hash}`)}
                    className='wuhu-button flex-1'
                  >
                    Continue
                  </button>
                  <button
                    type='button'
                    onClick={() =>
                      setDecoded(null)}
                    className='wuhu-button-secondary'
                  >
                    Discard
                  </button>
                </div>
              </div>
            )}
            <video
              ref={video}
              playsInline
              muted
              data-wuhu-scan-preview
              className={`wuhu-scan-preview mt-5 ${scanning ? '' : 'hidden'}`}
            />
            {scanning
              ? (
                <button
                  type='button'
                  onClick={stopScan}
                  className='wuhu-button-secondary wuhu-button-block mt-2'
                >
                  Stop scanning
                </button>
              )
              : (
                <div
                  data-dragging={dragging}
                  onDragOver={(event) => {
                    event.preventDefault()
                    setDragging(true)
                  }}
                  onDragLeave={() => setDragging(false)}
                  onDrop={(event) => {
                    event.preventDefault()
                    setDragging(false)
                    acceptImage(event.dataTransfer.files[0])
                  }}
                  className='wuhu-dropzone mt-5'
                >
                  …or scan the QR code
                  <button
                    type='button'
                    onClick={() => void startScan()}
                    className='wuhu-button-secondary wuhu-button-block mt-2'
                  >
                    Scan with camera
                  </button>
                  <button
                    type='button'
                    onClick={() => picker.current?.click()}
                    className='wuhu-button-secondary wuhu-button-block mt-2'
                  >
                    Choose a photo…
                  </button>
                  <input
                    ref={picker}
                    type='file'
                    accept='image/*'
                    className='hidden'
                    onChange={(event) => {
                      acceptImage(event.target.files?.[0])
                      event.target.value = ''
                    }}
                  />
                </div>
              )}
            {error && <p className='wuhu-alert mt-3'>{error}</p>}
          </div>
        </main>
      </div>
    </div>
  )
}
