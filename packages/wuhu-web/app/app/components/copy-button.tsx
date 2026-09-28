import { useState } from 'react'

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  return (
    <button
      type='button'
      aria-label='Copy message'
      data-wuhu-copy
      className='wuhu-quiet-button'
      onClick={() => {
        void navigator.clipboard.writeText(text).then(() => {
          setCopied(true)
          setTimeout(() => setCopied(false), 1200)
        })
      }}
    >
      {copied ? 'copied' : 'copy'}
    </button>
  )
}
