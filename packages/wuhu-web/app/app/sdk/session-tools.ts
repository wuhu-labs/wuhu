import { api } from './http'
import type {
  ToolRosterDescriptor,
  ToolRostersOutput,
} from '~/lib/contract.gen'

export async function fetchToolRosters(): Promise<ToolRosterDescriptor[]> {
  const output = await api<ToolRostersOutput>('/v1/session-tools')
  return output.rosters
}
