# DeploymentAdmin

`DeploymentAdminPolicy.load()` reads only `/etc/wuhu/admin-exec.json`, returning nil when absent. Any other open failure, symlink, nonregular/multiply-linked file, non-root owner, group/world write permission, empty UID set or oversized/malformed JSON refuses. The nonempty `allowedUIDs` set defines the OS users trusted for local deployment administration; environment variables and command-line flags cannot replace it.

`requireMachineAgentUser()` refuses a configured administrator UID and treats absent policy as unrestricted machine-agent use. `admitMachineAgent()` acquires a validated 0600 UID-owned single-link role file under the system temporary root and a shared nonblocking OS lock before checking policy. Its opaque `MachineAdmission` retains the close-on-exec descriptor until released. The v2 machine agent holds it for its complete lifetime, including in-process embeddings, retaining its per-UID machine role for that lifetime. No secret or caller-controlled identity is stored there.


File-decoding and UID-decision test seams are internal. No public policy constructor, environment selector or policy-path argument exists. Tests cover missing policy compatibility, owner/mode/symlink refusal, denied UID startup.
