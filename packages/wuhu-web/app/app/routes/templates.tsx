import { useCallback, useEffect, useState } from 'react'
import { Link, useOutletContext } from 'react-router'
import { Pill } from '@wuhu/ui'
import { TemplateCreateDialog } from '~/components/template-create'
import type { SessionTemplateDescriptor } from '~/lib/contract.gen'
import { fileHref } from '~/lib/links'
import { templateDirectory, templateLine } from '~/lib/templates'
import { errorMessage } from '~/sdk/errors'
import { fetchTemplates } from '~/sdk/templates'
import type { SpaceContext } from './space'

export function meta() {
  return [{ title: 'Templates · Wuhu' }]
}

function TemplateCard(
  { template, group }: { template: SessionTemplateDescriptor; group: string },
) {
  return (
    <article className='wuhu-card wuhu-template-card'>
      <div className='wuhu-template-card-head'>
        <span className='wuhu-template-name'>{template.name}</span>
        <Pill>{template.kind ?? 'any'}</Pill>
        <Link
          className='wuhu-quiet-button wuhu-template-open'
          to={fileHref(templateDirectory(template.name), group)}
        >
          Open
        </Link>
      </div>
      <p className='wuhu-mono'>{templateLine(template)}</p>
      {template.description && (
        <p className='wuhu-muted'>{template.description}</p>
      )}
    </article>
  )
}

export default function Templates() {
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
    <div className='wuhu-content wuhu-page'>
      <p className='wuhu-eyebrow'>Space</p>
      <div className='wuhu-templates-head'>
        <h1 className='wuhu-title'>Templates</h1>
        <button
          type='button'
          className='wuhu-button'
          onClick={() => setCreating(true)}
        >
          New template
        </button>
      </div>
      <p className='wuhu-muted wuhu-templates-lede'>
        A template is a reusable brief plus a model choice. New sessions created
        from one start with its AGENTS.md in their home and its provider, model
        and effort filled in — the same idea as a Claude Code agent.
      </p>
      {error && <p className='wuhu-alert'>{error}</p>}
      {!error && templates == null && <p className='wuhu-muted'>Loading…</p>}
      {templates != null && templates.length === 0 && (
        <p className='wuhu-muted wuhu-templates-empty'>No templates yet.</p>
      )}
      {templates != null && templates.length > 0 && (
        <div className='wuhu-template-list'>
          {templates.map((template) => (
            <TemplateCard
              key={template.name}
              template={template}
              group={group}
            />
          ))}
        </div>
      )}
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
    </div>
  )
}
