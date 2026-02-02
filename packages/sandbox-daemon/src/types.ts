export type SandboxDaemonScope = 'control' | 'observer'

export interface SandboxDaemonJwtClaims {
  iss?: string
  sub: string
  scope: SandboxDaemonScope
  exp: number
}

export interface SandboxDaemonCredentialsPayload {
  version: string
  llm?: {
    anthropicApiKey?: string | null
    openaiApiKey?: string | null
  }
  github?: {
    token: string
    username?: string
    email?: string
  }
  extra?: {
    env?: Record<string, string>
  }
}

export interface SandboxDaemonRepoConfig {
  /**
   * Human-readable identifier for this repo in the workspace,
   * e.g. "axiia-website".
   */
  id: string
  /**
   * Source locator, e.g. "github:owner/repo" or a git URL.
   */
  source: string
  /**
   * Relative path inside the daemon workspace where the repo
   * should be cloned or checked out.
   */
  path: string
  /**
   * Branch or ref to check out. Optional; implementation may
   * use the default branch when omitted.
   */
  branch?: string
}

export type SandboxDaemonGitCheckpointMode = 'off' | 'per-turn' | 'mock'

export interface SandboxDaemonGitCheckpointConfig {
  mode: SandboxDaemonGitCheckpointMode
  branchName?: string
  commitMessageTemplate?: string
  remote?: string
  push?: boolean
}

export type SandboxDaemonAgentMode = 'pi-rpc' | 'mock'

export interface SandboxDaemonAgentConfig {
  mode: SandboxDaemonAgentMode
}

export interface SandboxDaemonInitRequest {
  workspace: {
    repos: SandboxDaemonRepoConfig[]
  }
  gitCheckpoint?: SandboxDaemonGitCheckpointConfig
  agent?: SandboxDaemonAgentConfig
}

export interface SandboxDaemonInitRepoSummary {
  id: string
  path: string
  currentBranch?: string
}

export interface SandboxDaemonInitResponse {
  ok: boolean
  workspace: {
    repos: SandboxDaemonInitRepoSummary[]
  }
}

export interface SandboxDaemonPromptRequest {
  message: string
  images?: unknown[]
  streamingBehavior?: 'steer' | 'followUp'
}

export interface SandboxDaemonPromptResponse {
  success: boolean
  command: 'prompt'
}

export interface SandboxDaemonAbortRequest {
  reason?: string
}

export interface SandboxDaemonAbortResponse {
  success: boolean
  command: 'abort'
}

export interface SandboxDaemonStreamEnvelope<TEvent = unknown> {
  cursor: number
  event: TEvent
}

export type SandboxDaemonEventSource = 'daemon' | 'agent'

export interface SandboxDaemonBaseEvent {
  source: SandboxDaemonEventSource
  type: string
}

export interface SandboxDaemonRepoClonedEvent extends SandboxDaemonBaseEvent {
  source: 'daemon'
  type: 'repo_cloned'
  repoId: string
  path: string
}

export interface SandboxDaemonRepoCloneErrorEvent extends SandboxDaemonBaseEvent {
  source: 'daemon'
  type: 'repo_clone_error'
  repoId: string
  error: string
}

export interface SandboxDaemonCheckpointCommitEvent extends SandboxDaemonBaseEvent {
  source: 'daemon'
  type: 'checkpoint_commit'
  repoId: string
  branch: string
  commitSha: string
  turn: number
  pushed: boolean
}

export type SandboxDaemonDaemonEvent =
  | SandboxDaemonRepoClonedEvent
  | SandboxDaemonRepoCloneErrorEvent
  | SandboxDaemonCheckpointCommitEvent

export interface SandboxDaemonAgentEvent extends SandboxDaemonBaseEvent {
  source: 'agent'
  /**
   * The raw event object emitted by the underlying coding agent.
   * For Protocol 0 in pi mode this is a pi RPC AgentEvent.
   */
  payload: {
    type: string
    [key: string]: unknown
  }
}

export type SandboxDaemonEvent =
  | SandboxDaemonDaemonEvent
  | SandboxDaemonAgentEvent

export interface SandboxDaemonClient {
  setCredentials(payload: SandboxDaemonCredentialsPayload): Promise<void>
  init(request: SandboxDaemonInitRequest): Promise<SandboxDaemonInitResponse>
  prompt(request: SandboxDaemonPromptRequest): Promise<SandboxDaemonPromptResponse>
  abort(request?: SandboxDaemonAbortRequest): Promise<SandboxDaemonAbortResponse>
}

