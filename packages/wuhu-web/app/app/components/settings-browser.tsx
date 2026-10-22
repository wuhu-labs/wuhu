import {
  type SendKey,
  sendKeyLabel,
  setSendKey,
  useSendKey,
} from '~/lib/composer'
import { WebPushControl } from './web-push-control'

// Choices this browser keeps for itself.
export function BrowserCard() {
  const key = useSendKey()
  return (
    <section className='wuhu-card wuhu-settings-card'>
      <p className='wuhu-muted'>
        These stay in this browser. Your other devices keep their own.
      </p>
      <label className='wuhu-field wuhu-field-wide'>
        <span>send with</span>
        <select
          value={key}
          onChange={(event) => setSendKey(event.target.value as SendKey)}
        >
          {(['shift-enter', 'enter'] as const).map((option) => (
            <option key={option} value={option}>
              {sendKeyLabel(option)}
            </option>
          ))}
        </select>
      </label>
      <WebPushControl />
    </section>
  )
}
