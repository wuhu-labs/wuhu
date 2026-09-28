import { api } from './http'
import type { ProviderDescriptor, ProvidersOutput } from '~/lib/contract.gen'

export async function fetchProviders(): Promise<ProviderDescriptor[]> {
  const output = await api<ProvidersOutput>('/v1/providers')
  return output.providers
}
