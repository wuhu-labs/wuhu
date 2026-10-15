import { api } from './http'
import type { ProviderDescriptor, ProvidersOutput } from '~/lib/contract.gen'
import { type ModelCatalog, selectableProviders } from '~/lib/session-create'

export async function fetchProviders(): Promise<ProviderDescriptor[]> {
  const output = await api<ProvidersOutput>('/v1/providers')
  return output.providers
}

// What a session can run on: providers with models, and model groups.
export async function fetchModelCatalog(): Promise<ModelCatalog> {
  const output = await api<ProvidersOutput>('/v1/providers')
  return {
    providers: selectableProviders(output.providers),
    groups: output.groups ?? [],
  }
}
