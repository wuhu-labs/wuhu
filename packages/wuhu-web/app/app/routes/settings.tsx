import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { Link, useLocation, useOutletContext } from 'react-router'
import { policyLinks } from '~/components/ai-sharing-dialog'
import { Avatar } from '~/components/avatar'
import { BrowserCard } from '~/components/settings-browser'
import { GroupSettings } from '~/components/settings-groups'
import {
  settingsPlace,
  type SettingsRow,
  settingsRowLabel,
} from '~/components/settings-nav'
import { UsageCard } from '~/components/settings-usage'
import { TemplateCreateDialog } from '~/components/template-create'
import type { SessionTemplateDescriptor } from '~/lib/contract.gen'
import { displayNameFor, handleFor } from '~/lib/directory'
import { inviteCountdown } from '~/lib/invite'
import { fileHref } from '~/lib/links'
import { qrModules, qrSvgPath } from '~/lib/qr'
import { templateDirectory, templateLine } from '~/lib/templates'
import {
  profileChangedEvent,
  setOwnHandle,
  useDirectory,
  useOwnPrincipal,
} from '~/lib/use-directory'
import type { SpaceContext } from '~/routes/space'
import { enrolledDevice, logout } from '~/sdk/auth'
import { uploadAvatar } from '~/sdk/avatar'
import { errorMessage } from '~/sdk/errors'
import {
  mintShareLogin,
  revokeInvite,
  type ShareLogin,
} from '~/sdk/share-login'
import { fetchTemplates } from '~/sdk/templates'

export function meta() {
  return [{ title: 'Settings · Wuhu' }]
}

// The selected row's detail; the rows themselves are the sidebar's
// (components/settings-nav.tsx).
export default function Settings() {
  const search = useLocation().search
  const { row, topic } = settingsPlace(search)
  const { sidebarCatalog } = useOutletContext<SpaceContext>()
  if (topic === 'groups') {
    return <GroupSettings catalog={sidebarCatalog} />
  }
  return (
    <div className='wuhu-content wuhu-settings'>
      <h1 className='wuhu-settings-title'>{settingsRowLabel(row)}</h1>
      <SettingsDetail row={row} />
    </div>
  )
}

function SettingsDetail({ row }: { row: SettingsRow }) {
  const { contentOrigin, reviewAISharing } = useOutletContext<SpaceContext>()
  const [enrolled, setEnrolled] = useState(false)

  useEffect(() => {
    let cancelled = false
    enrolledDevice()
      .then((device) => {
        if (!cancelled) setEnrolled(device != null)
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [])

  const signOut = () => {
    void logout(typeof contentOrigin === 'string' ? contentOrigin : null)
      .catch(() => undefined)
      .finally(() => globalThis.location.assign('/'))
  }

  switch (row) {
    case 'profile':
      return <ProfileCard />
    case 'devices':
      return <DevicesCard signOut={enrolled ? signOut : null} />
    case 'browser':
      return <BrowserCard />
    case 'ai-sharing':
      return <PrivacyCard review={reviewAISharing} />
    case 'templates':
      return <TemplatesCard />
    case 'usage':
      return <UsageCard />
  }
}

function TemplatesCard() {
  const { group } = useOutletContext<SpaceContext>()
  const [templates, setTemplates] = useState<
    SessionTemplateDescriptor[] | null
  >(null)
  const [error, setError] = useState<string | null>(null)
  const [creating, setCreating] = useState(false)

  const load = useCallback(() => {
    fetchTemplates(group).then(
      (found) => {
        setTemplates(found)
        setError(null)
      },
      (failure: unknown) => setError(errorMessage(failure)),
    )
  }, [group])

  useEffect(load, [load])

  return (
    <section className='wuhu-card wuhu-settings-card'>
      <p className='wuhu-muted'>
        A template is a reusable brief plus a model choice. New sessions created
        from one start with its AGENTS.md in their home and its provider, model
        and effort filled in.
      </p>
      {error && <p className='wuhu-alert'>{error}</p>}
      {!error && templates == null && <p className='wuhu-muted'>Loading…</p>}
      {templates != null && templates.length === 0 && (
        <p className='wuhu-muted'>No templates yet.</p>
      )}
      {templates?.map((template) => (
        <div key={template.name} className='wuhu-template'>
          <Link to={fileHref(templateDirectory(template.name), group)}>
            <strong>{template.name}</strong>
            <span className='wuhu-muted'>{template.kind ?? 'any'}</span>
          </Link>
          <p className='wuhu-mono'>{templateLine(template)}</p>
          {template.description && (
            <p className='wuhu-muted'>{template.description}</p>
          )}
        </div>
      ))}
      <div className='wuhu-form-actions'>
        <button
          type='button'
          className='wuhu-button'
          onClick={() => setCreating(true)}
        >
          New template
        </button>
      </div>
      <TemplateCreateDialog
        open={creating}
        taken={(name) =>
          templates?.some((template) => template.name === name) ?? false}
        onClose={() => setCreating(false)}
        onCreated={() => {
          setCreating(false)
          load()
        }}
      />
    </section>
  )
}

function ProfileCard() {
  const directory = useDirectory()
  const principal = useOwnPrincipal()
  const picker = useRef<HTMLInputElement>(null)
  const [handle, setHandle] = useState<string | null>(null)
  const [displayName, setDisplayName] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const knownHandle = principal == null
    ? undefined
    : handleFor(directory, principal)
  const knownName = principal == null
    ? undefined
    : displayNameFor(directory, principal)
  const handleDraft = handle ?? knownHandle ?? ''
  const nameDraft = displayName ?? knownName ?? ''

  const save = () => {
    setBusy(true)
    setError(null)
    setOwnHandle(handleDraft.trim(), nameDraft.trim())
      .then(() => {
        setHandle(null)
        setDisplayName(null)
      })
      .catch((failure: unknown) => setError(errorMessage(failure)))
      .finally(() => setBusy(false))
  }

  const pick = (file: File | undefined) => {
    if (file == null || principal == null) return
    setBusy(true)
    setError(null)
    uploadAvatar(principal, file)
      .then(() => globalThis.dispatchEvent(new Event(profileChangedEvent)))
      .catch((failure: unknown) => setError(errorMessage(failure)))
      .finally(() => setBusy(false))
  }

  return (
    <section className='wuhu-card wuhu-settings-card'>
      <div className='wuhu-profile-row'>
        <div className='wuhu-avatar-picker'>
          <Avatar
            principal={principal}
            name={nameDraft === '' ? handleDraft : nameDraft}
            size={64}
          />
          <button
            type='button'
            className='wuhu-quiet-button'
            disabled={busy || principal == null}
            onClick={() => picker.current?.click()}
          >
            Change
          </button>
          <input
            ref={picker}
            type='file'
            accept='image/*'
            hidden
            onChange={(event) => {
              pick(event.target.files?.[0])
              event.target.value = ''
            }}
          />
        </div>
        <div className='wuhu-profile-fields'>
          <label className='wuhu-field wuhu-field-wide'>
            <span>display name</span>
            <input
              placeholder='How you want to be named'
              value={nameDraft}
              disabled={busy}
              onChange={(event) => setDisplayName(event.target.value)}
            />
          </label>
          <label className='wuhu-field wuhu-field-wide'>
            <span>handle</span>
            <div className='wuhu-handle-edit'>
              <span>@</span>
              <input
                aria-label='Handle'
                placeholder='handle'
                value={handleDraft}
                disabled={busy}
                onChange={(event) => setHandle(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') save()
                }}
              />
            </div>
          </label>
        </div>
      </div>
      <div className='wuhu-form-actions'>
        {error && <span className='wuhu-alert'>{error}</span>}
        <button
          type='button'
          className='wuhu-button'
          disabled={busy || handleDraft.trim() === ''}
          onClick={save}
        >
          Save
        </button>
      </div>
    </section>
  )
}

function DevicesCard({ signOut }: { signOut: (() => void) | null }) {
  const [invite, setInvite] = useState<ShareLogin | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [now, setNow] = useState(() => new Date())

  useEffect(() => {
    if (invite == null) return
    const tick = setInterval(() => setNow(new Date()), 1000)
    return () => clearInterval(tick)
  }, [invite])

  const mint = () => {
    setBusy(true)
    setError(null)
    setCopied(false)
    mintShareLogin()
      .then((minted) => {
        setInvite(minted)
        setNow(new Date())
      })
      .catch((failure: unknown) => setError(errorMessage(failure)))
      .finally(() => setBusy(false))
  }

  const revoke = () => {
    if (invite == null) return
    setBusy(true)
    setError(null)
    revokeInvite(invite.token)
      .then(() => setInvite(null))
      .catch((failure: unknown) => setError(errorMessage(failure)))
      .finally(() => setBusy(false))
  }

  return (
    <section className='wuhu-card wuhu-settings-card'>
      <p className='wuhu-muted'>
        Scan from the phone's Wuhu login page, or open the link. One-time,
        expires in 10 minutes.
      </p>
      {invite && (
        <div className='wuhu-invite'>
          <InviteCode url={invite.url} />
          <div className='wuhu-panel wuhu-invite-url'>
            <div className='wuhu-panel-code'>{invite.url}</div>
          </div>
          <div className='wuhu-invite-meta'>
            <span>{inviteCountdown(invite.expiresAt, now)}</span>
            <button
              type='button'
              className='wuhu-quiet-button'
              onClick={() => {
                void navigator.clipboard?.writeText(invite.url)
                setCopied(true)
              }}
            >
              {copied ? 'Copied' : 'Copy'}
            </button>
            <button
              type='button'
              className='wuhu-quiet-button'
              disabled={busy}
              onClick={revoke}
            >
              Revoke
            </button>
          </div>
        </div>
      )}
      {error && <p className='wuhu-alert'>{error}</p>}
      <div className='wuhu-form-actions'>
        {signOut && (
          <button
            type='button'
            className='wuhu-quiet-button wuhu-settings-logout'
            onClick={signOut}
          >
            Log out
          </button>
        )}
        <button
          type='button'
          className='wuhu-button'
          disabled={busy}
          onClick={mint}
        >
          Invite a device
        </button>
      </div>
    </section>
  )
}

function PrivacyCard({ review }: { review: () => void }) {
  return (
    <section className='wuhu-card wuhu-settings-card'>
      <button type='button' className='wuhu-settings-link' onClick={review}>
        <strong>AI sharing</strong>
        <span className='wuhu-muted'>
          Review or withdraw permission for AI sharing in this space.
        </span>
      </button>
      <div className='wuhu-settings-links'>
        <a href={policyLinks.privacy} target='_blank' rel='noreferrer'>
          Privacy Policy
        </a>
        <a href={policyLinks.terms} target='_blank' rel='noreferrer'>
          Terms of Use
        </a>
        <a href={policyLinks.support} target='_blank' rel='noreferrer'>
          Support
        </a>
      </div>
    </section>
  )
}

const quietZone = 4

function InviteCode({ url }: { url: string }) {
  const { size, path } = useMemo(() => {
    const modules = qrModules(url)
    return { size: modules.length, path: qrSvgPath(modules) }
  }, [url])
  const span = size + quietZone * 2
  return (
    <svg
      className='wuhu-invite-qr'
      viewBox={`${-quietZone} ${-quietZone} ${span} ${span}`}
      shapeRendering='crispEdges'
      role='img'
      aria-label='Invite QR code'
    >
      <path d={path} fill='currentColor' />
    </svg>
  )
}
