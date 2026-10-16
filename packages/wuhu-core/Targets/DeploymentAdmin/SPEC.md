# DeploymentAdmin

`DeploymentAdminPolicy.load()` reads only `/etc/wuhu/admin-exec.json`, returning nil when absent. Any other open failure, symlink, nonregular/multiply-linked file, non-root owner, group/world write permission, empty UID set or oversized/malformed JSON refuses. The nonempty `allowedUIDs` set defines the OS users trusted for local deployment administration; environment variables and command-line flags cannot replace it.

`requireMachineAgentUser()` refuses a configured administrator UID and treats absent policy as unrestricted machine-agent use. `admitMachineAgent()` acquires a validated 0600 UID-owned single-link role file under the system temporary root and a shared nonblocking OS lock before checking policy. Its opaque `MachineAdmission` retains the close-on-exec descriptor until released. Both machine-agent implementations hold it for their complete lifetimes, including in-process embeddings, so policy installed after startup still exposes their presence. No secret or caller-controlled identity is stored there.

`requireNoMachineAgents()` refuses an allowed UID with a live shared role lock, unsafe/unavailable role storage, or a kernel-inventoried existing CLI machine agent. Legacy inventory failures refuse rather than assuming absence. It closes successful exclusive role probes immediately. This startup check plus the agent's policy check separates administrator UIDs from machine execution UIDs; the root administrator controls policy installation and removal.

File-decoding and UID-decision test seams are internal. No public policy constructor, environment selector or policy-path argument exists. Tests cover missing policy compatibility, owner/mode/symlink refusal, denied UID startup and existing-agent overlap.
