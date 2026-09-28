import { api, inGroup } from './http'
import type {
  SessionTemplateDescriptor,
  SessionTemplatesOutput,
} from '~/lib/contract.gen'

export async function fetchTemplates(
  group: string,
): Promise<SessionTemplateDescriptor[]> {
  const output = await api<SessionTemplatesOutput>('/v1/templates', {
    headers: inGroup(group),
  })
  return output.templates
}
