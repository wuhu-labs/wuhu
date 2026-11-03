import { claim } from "wuhu:host"
import { CapabilityError } from "wuhu:ai"
const { host, guarded, signal } = claim()

export { CapabilityError }
export const webSearch = async (query, options = {}) => {
  const value = await guarded(signal, () => host.web_search(query, options))
  if (value.error) throw new CapabilityError(value.error)
  return value.ok
}
export default webSearch
