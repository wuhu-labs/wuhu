import { ModalDialog } from '~/components/modal-dialog'
import type { AISharing } from '~/lib/ai-sharing'

export const policyLinks = {
  privacy: 'https://wuhu.ai/privacy',
  terms: 'https://wuhu.ai/terms',
  support: 'https://wuhu.ai/support',
}

export function AISharingDialog({
  open,
  space,
  server,
  decision,
  onChoose,
  onClose,
}: {
  open: boolean
  space: string
  server: string
  decision: AISharing | null
  onChoose: (decision: AISharing) => void
  onClose: () => void
}) {
  const allowed = decision === 'allowed'
  return (
    <ModalDialog open={open} title='AI sharing' onClose={onClose}>
      <div className='wuhu-ai-sharing'>
        <div>
          <strong>{space}</strong>
          <div className='wuhu-mono'>{server}</div>
        </div>
        <p>
          This space is hosted by its operator. When you use AI, your messages,
          attached images, relevant space documents and tool results can be sent
          to the AI providers and agent executors configured by that operator.
        </p>
        <p>
          If you use dictation, your audio is sent to the space and its
          configured transcription provider. Providers may process and retain
          data under their own policies. Agents can also use tools and connected
          services chosen by the operator.
        </p>
        <p>
          Providers can include OpenAI, Anthropic, Google, DeepSeek or another
          service. Ask your space operator which providers and tools are enabled
          before allowing sharing. The app does not verify their privacy
          practices, and the operator can change the configuration.
        </p>
        <p>
          This choice applies to AI actions from this browser in this space. You
          can still read the space without allowing. Withdrawing permission
          stops new AI requests from this browser; it does not cancel work
          already running on the server or delete data already shared.
        </p>
        <p>
          <a href={policyLinks.privacy} target='_blank' rel='noreferrer'>
            Read the Privacy Policy
          </a>
          {' · '}
          <a href={policyLinks.terms} target='_blank' rel='noreferrer'>
            Terms of Use
          </a>
        </p>
        <p className='wuhu-muted'>
          You can change this choice in Settings → AI sharing.
        </p>
      </div>
      <div className='wuhu-form-actions'>
        <button
          type='button'
          className='wuhu-button-secondary'
          onClick={() => onChoose('declined')}
        >
          {allowed ? 'Withdraw permission' : 'Continue without AI'}
        </button>
        <button
          type='button'
          className='wuhu-button'
          onClick={() => onChoose('allowed')}
        >
          {allowed ? 'Keep allowing' : 'Allow AI sharing'}
        </button>
      </div>
    </ModalDialog>
  )
}
