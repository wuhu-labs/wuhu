# Getting started

Wuhu is an LLM agent all-in-one workspace for individuals and small teams. Its
unit of deployment is a **space**: one folder served by one space server,
backed by one SQLite database, holding files, tables, revisions, sessions, and
channels. Three surfaces reach it:

- the **`wuhu` CLI** — files, tables, observation, machines, sessions,
  messaging ([wuhu-cli.md](wuhu-cli.md));
- the **web app** — a SPA embedded in the server binary, served on the API
  origin;
- **LLM sessions** — agents living inside the space, using the same tool
  contract as everything else.

There is no privileged side channel: the CLI, the web app, and sessions all go
through the same `/v1` surface ([http-api.md](http-api.md)).

## Building the `wuhu` binary

The server and CLI are one binary. From a checkout of this repo, with
Bazelisk, Deno, and either macOS 26 with Xcode 26.4 or Linux with Swift 6.3:

```bash
bazel build //packages/wuhu-core:wuhu
install -m 755 .bazel/bin/packages/wuhu-core/wuhu ~/.local/bin/wuhu
```

Use `install`, not `cp`, when upgrading over an existing binary: on macOS
`cp` mutates the file in place and the kernel's stale signature cache
SIGKILLs the new binary on exec (exit 137); `install` unlinks first, so the
replacement gets a fresh inode.

The Bazel build compiles the `packages/wuhu-web` SPA in the build graph (the
`//packages/wuhu-web:bundle` action needs network access to fetch the
lockfile-pinned npm dependencies) and embeds it, along with the bundled agent
skills — a plain SwiftPM build has neither.

## First space

```bash
wuhu serve ~/my-space --dev
```

This creates the folder, opens (or creates) `~/my-space/space.sqlite` and
binds two origins on `127.0.0.1`. Nothing is written into a new space: the
system manual and skills ship in the binary at `wuhu://system/`. `--dev` turns
authentication off, which suits a space only this machine can reach; see
[Authentication](#authentication) for the rest.

- **API origin** on `:5540` — `/v1` routes plus the embedded web app on every
  non-`/v1` GET. Open `https://localhost:5540/` in a browser (the server
  always speaks TLS; the self-signed certificate shows a one-time
  interstitial — use `--cert`/`--key` or mkcert if that bothers you).
- **Web-content origin** on `:5541` — the space's own files served raw
  (`index.html` / `index.md` resolution then a generated directory listing,
  MIME by extension), with the
  page-embedded data APIs under `/_/`.

Then, from any working folder, pin the space and start working:

```bash
wuhu use localhost:5540 --pin
wuhu write /notes/plan.md --body "# Plan"
wuhu ls /
```

`use` records the space in a `./.wuhu` wallet directory (per checkout, found
by walking up), and `--pin` records the self-signed certificate's fingerprint
in the user-level `~/.wuhu/trust.json`; see the
[wallet section of wuhu-cli.md](wuhu-cli.md#wallet).

`--dev-import <folder>` imports a plain folder into the space on boot, and
`--dev-export <folder>` dumps it back to disk on graceful shutdown — useful
for keeping a space's content in a git repo during development.

## Transport: TLS always

Both origins always speak TLS with ALPN-negotiated HTTP/2 (http/1.1
fallback) — including on localhost; there is no plaintext mode and no flag
to disable verification. On first serve a self-signed certificate (SANs:
`localhost`, `127.0.0.1`, `::1`) is generated into `<folder>/tls` and
reused; the fingerprint is logged loudly at startup. Clients verify against
the OS trust store by default; for a self-signed server, `wuhu use <host:port>
--pin` records the fingerprint explicitly into the user-level
`~/.wuhu/trust.json`, and `machine join` pre-records the fingerprint printed
by `machine add` (see [wuhu-cli.md](wuhu-cli.md)); browsers get a one-time
interstitial.

The server keeps one VAPID private key at `<space>/web-push/vapid.json`
(directory mode `0700`, file mode `0600`). Keep that server-owned secret with
the space when moving or backing it up; replacing it invalidates browser push
subscriptions.

Both listeners bind `127.0.0.1` unless `--host` names another address, so a
space is reachable from this machine only until you pass `--host 0.0.0.0` (or
a specific interface address).

The serious install shape is port 443 with **two hostnames** — one for the
API/SPA origin and one for the web-content origin — and a real certificate
via `--cert <pem> --key <pem>` covering both, bound with `--host 0.0.0.0` (or
the interface that faces your clients). Advertise the API/SPA
hostname with `--origin https://space.example.com` so share-login and
invite links carry the public name instead of whatever address the
minting wallet happens to use, and the web-content
hostname with `--web-origin https://content.example.com`; clients discover
both through `GET /v1/server` instead of deriving port + 1. Binding 443 needs
the usual privilege arrangement for your platform (setcap, launchd, or a
port redirect); that mechanics is out of scope here.

## Authentication

Without `--dev`, the API origin admits enrolled devices only. Every `/v1`
request needs a bearer assertion signed by an enrolled device key; an
anonymous one gets `401 unauthorized`, `this space admits enrolled devices
only`. A few routes carry their own credential or are public discovery and
pass the wall: `GET /v1/machine/connect` and `GET /v1/machine/challenge` (a
machine's signed challenge), `POST /v1/enroll/consume` (the join token it
burns), `POST /v1/enroll/share-login` and `GET /v1/enroll/share-login/challenge`
(an enrolled key's signed challenge), `GET /v1/server` and `GET /v1/groups`.
The embedded web app's static GETs pass too. The web-content origin has its
own wall: content reads need a read cookie minted from an enrolled device,
unless the server runs with `--public-read`, which opens content reads of the
`shared` group (the bare host) to anyone. A group host still needs a read
cookie, and writes and the API origin stay walled.

`--dev` drops both walls: every caller acts as the space owner. With the
default `--host 127.0.0.1` that is anyone on this machine; don't combine it
with an exposed `--host`.

The first device of a space is enrolled offline, from the space folder itself
(possession of the folder is root), with the server stopped:

```bash
wuhu serve ~/my-space --host 0.0.0.0 --origin https://space.example.com:5540
# ctrl-c once it is up: the first boot records the origin and TLS fingerprint
wuhu user add --space ~/my-space --name me          # prints the account id; the first account is admin
wuhu user invite --space ~/my-space <account-id> > invite.txt
wuhu serve ~/my-space --host 0.0.0.0 --origin https://space.example.com:5540
```

The invite link (`https://<origin>/_/enroll#token=jt_…&space=spc_…&fp=sha256:…`)
carries the certificate fingerprint recorded at boot and expires after an hour
(`--ttl <seconds>`). Without `--origin`, pass `--server https://<host>:<port>` to
`user invite`. On the device, enroll and pin:

```bash
wuhu login < invite.txt
wuhu use space.example.com:5540
```

`wuhu login` records the fingerprint as a pin, generates this device's key for
the space and enrolls it; the link dies at first use. The browser takes the
same link. From an enrolled device, `wuhu share-login` mints a one-time link
(and a terminal QR code) for another device of your account. `user add` and
`user invite` are the offline path; with the server running, an admin creates
accounts and mints their invites over `POST /v1/accounts` and `POST /v1/enroll`,
and lists or removes them with `wuhu user list|remove`. See
[wuhu-cli.md](wuhu-cli.md#device-enrollment) and
[http-api.md](http-api.md#enrollment).

## Sessions

To run LLM sessions in the space, the server needs provider credentials.
Store them on the serving host with `wuhu auth` (per-space file under
`~/.wuhu/credentials/`), or export environment variables, which take
precedence — `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY` (the
pattern is the provider id from `/models.json`, uppercased, `-` → `_`, plus
`_API_KEY`). Seed the model catalog once:

```bash
wuhu models update
wuhu auth set anthropic < key.txt        # or env ANTHROPIC_API_KEY
wuhu auth login codex                    # ChatGPT subscription models
wuhu session create --provider anthropic --model claude-sonnet-5 "First session"
wuhu send <session-id> "hello" --wait
```

The session verbs are in [wuhu-cli.md](wuhu-cli.md#sessions-and-messaging).

## Machines

A space can adopt remote boxes for command execution and raw filesystem
access; see the machine verbs in
[wuhu-cli.md](wuhu-cli.md#machines-exec-vault).

## Where to go next

- [wuhu-cli.md](wuhu-cli.md) — the complete verb reference.
- [http-api.md](http-api.md) — the `/v1` routes.
- [Space tools](../packages/wuhu-core/Targets/SpaceToolReference/Tests/reference/README.md) — one page per tool behind `POST /v1/tools/:name`.
- [wire-schemas.md](wire-schemas.md) — the generated JSON Schemas of every request and response.
