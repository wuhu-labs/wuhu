---
title: Models and credentials
---
# Models and credentials

Wuhu brings no model. You connect your own accounts on the server's host, and every agent in the space uses them.

## Connecting an account

Run these on the server's host, as the user that runs the server:

- `wuhu auth login codex`: sign in with your ChatGPT account. It shows a code to confirm in your browser.
- `wuhu auth set <provider> < key.txt`: an API key, on stdin, for any provider in the catalog or any search, image or transcription provider below.

`wuhu auth list` shows what's connected; `wuhu auth remove <provider>` removes one. An environment variable such as `ANTHROPIC_API_KEY` on the server wins over the stored key.

Keys live in `~/.wuhu/credentials/<space-id>.json` on the server's host. They are not in the space folder, and no client ever receives them.

They belong to the whole space, not to a group: everyone's agents use the same accounts. If friends share your space, they spend your subscription.

## The model catalog

`/models.json` in the `shared` group lists the providers and their models: the API style, the base URL, each model's context and output limits, and its reasoning efforts. You pick from it when you start an agent.

It ships with Anthropic (`anthropic`), OpenAI by API key (`openai`) or ChatGPT subscription (`codex`), and DeepSeek. It's a document like any other, so you or an agent can add a provider or a model. The provider has to speak one of the API styles Wuhu supports: Anthropic Messages, OpenAI Responses or ChatGPT Codex. OpenAI Chat Completions alone isn't enough, which rules out some local servers.

`wuhu models update` merges the list that ships with the CLI into it, without overwriting your edits. Run it in `shared`: `wuhu --group shared models update`.

## Search, images and transcription

Agents can search the web, make and edit images, and transcribe audio, and the apps use transcription for dictation. The CLI has them too: `wuhu web-search`, `wuhu image`, `wuhu transcribe`.

If you signed in with `wuhu auth login codex`, all three already work, through your ChatGPT account. Nothing else to set up.

To use other providers, write `/capabilities.json` in `shared`. For each capability it lists the providers you have and which one is active:

- `web_search`: `codex`, `brave`, `exa`
- `image`: `codex`, `openai-images`, `dashscope` (Qwen)
- `transcription`: `codex`, `openai-audio`, `dashscope` (Qwen)

```json
{
  "web_search": {
    "active": "brave",
    "providers": { "brave": { "dialect": "brave" } }
  }
}
```

Then store the key under the provider's name: `wuhu auth set brave < key.txt`. A capability you leave out stays on Codex. One you name but haven't set up fails with an error; it doesn't fall back.

## Secrets

Agents' scripts and commands can use secrets too, e.g. a token for a web service. These are per group, and kept apart from the model keys above.

An admin of a group stores one with `wuhu secret set <NAME> < value`, acting in that group (`--group <id>`, as in [Groups](/guide/3-people-and-devices.md#groups)); `wuhu secret list` shows names and `wuhu secret remove <NAME>` deletes one. They live in `~/.wuhu/secrets/<space-id>/<group>.json` on the server's host. One group never sees another's.

A script's secrets come from its agent's group; the value is filled into its outgoing requests and masked in what comes back. A command on a machine gets its machine's group's secrets as environment variables. See [Machines](/guide/4-machines.md#secrets-on-the-machine).

## Keyless providers and server identity

A compatible provider can set `"auth": "oidc"` in its `/models.json` entry. Wuhu then signs a fresh 5-minute ES256 token for every kernel inference call and sends `Authorization: Bearer <jwt>`, without reading stored credentials. Anthropic Messages and OpenAI Responses support this; ChatGPT Codex and Claude Code do not. The provider must verify Wuhu's tokens: this does not make ordinary vendor API endpoints accept them. Capability authentication remains separate.

The token audience is the origin of the provider's `baseURL`, including an internal HTTP origin. The issuer is the server's configured HTTPS `--origin` (a hosted tenant's own host). No issuer or audience field is needed. Missing configuration or signing failure produces a typed error, never a fallback to a stored key or another provider.

The space host publishes unauthenticated `GET /.well-known/openid-configuration` (`issuer`, `jwks_uri`, supported `ES256` algorithm) and `GET /.well-known/jwks.json` (the public P-256 key and its `kid`). Without HTTPS `--origin`, both return HTTP 422 with code `oidcConfiguration`. Tokens include the space id, group id and acting session id, not names or emails. The signing key stays outside space documents at `<server-state>/identity/identity.p256` and survives restart and upgrade; preserve that state directory.
