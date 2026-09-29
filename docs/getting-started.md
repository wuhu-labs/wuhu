# Getting started

Wuhu is an LLM agent all-in-one workspace for individuals and small teams. Its
unit of deployment is a **space**: one folder served by one space server,
backed by one SQLite database, holding files, tables, revisions, sessions, and
channels. Three surfaces reach it:

- the **`wuhu` CLI** — files, tables, observation, machines, sessions,
  messaging ([wuhu-cli.md](wuhu-cli.md));
- the **web app** — a SPA embedded in the server binary, served on the space's host;
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

This creates the folder, opens (or creates) `~/my-space/space.sqlite` and binds one TLS port, `127.0.0.1:5530`. Nothing is written into a new space: the system manual and skills ship in the binary at `wuhu://system/`. `--dev` turns authentication off, which suits a space only this machine can reach; see [Authentication](#authentication) for the rest. The port answers by the name a request asks for:

- **The space's host**, `localhost:5530` here — `/v1` routes plus the embedded web app on every non-`/v1` GET. Open `https://localhost:5530/` in a browser (the server always speaks TLS; the self-signed certificate shows an interstitial, once per host — see [Transport](#transport-tls-always)). It serves no space content.
- **A group's host**, `<group>.localhost:5530` here (`shared.localhost:5530` for the `shared` group) — that group's files served raw (`index.html` / `index.md` resolution then a generated directory listing, MIME by extension), with the page-embedded data APIs under `/_/`. It serves no `/v1` route.

Without `--origin` the space's host is `localhost`; browsers and curl resolve every `*.localhost` name to loopback, so the group hosts work with no DNS setup. The web app also works opened as `https://127.0.0.1:5530/` or `https://[::1]:5530/`, and the serve banner prints `https://localhost:5530`.

Then, from any working folder, pin the space and start working:

```bash
wuhu use localhost:5530 --pin
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

The port always speaks TLS with ALPN-negotiated HTTP/2 (http/1.1 fallback) — including on localhost; there is no plaintext mode and no flag to disable verification. On first serve a self-signed certificate (SANs: `localhost`, `*.localhost`, `127.0.0.1`, `::1`) is generated into `<folder>/tls` and reused; the fingerprint is logged loudly at startup. Clients verify against the OS trust store by default; for a self-signed server, `wuhu use <host:port> --pin` records the fingerprint explicitly into the user-level `~/.wuhu/trust.json`, and `machine join` pre-records the fingerprint printed by `machine add` (see [wuhu-cli.md](wuhu-cli.md)). Invites, share-login links and machine join tokens carry the fingerprint only for this generated certificate: with `--cert`/`--key` (self-signed or not) they carry none, and every client must trust the certificate through its system trust store. A browser accepts a self-signed certificate per host: accepting it on `localhost:5530` does not cover `<group>.localhost:5530`, and a group's page framed in the web app fails to load until it is. Open each group host once at top level (`https://<group>.localhost:5530/`) and accept it there, or make a locally trusted certificate with [mkcert](https://github.com/FiloSottile/mkcert) (`mkcert localhost '*.localhost'`) and pass it as `--cert`/`--key`; invites then carry no fingerprint, so every device that enrolls must trust mkcert's CA. A space first served by an older release keeps a certificate in `<folder>/tls` that does not cover `*.localhost`: stop the server, delete `<folder>/tls` so the next serve generates a new one, and re-pin clients with `wuhu trust <host:port>`.

The server keeps one VAPID private key at `<space>/web-push/vapid.json`
(directory mode `0700`, file mode `0600`). Keep that server-owned secret with
the space when moving or backing it up; replacing it invalidates browser push
subscriptions.

The listener binds `127.0.0.1` unless `--host` names another address, so a space is reachable from this machine only until you pass `--host 0.0.0.0` (or a specific interface address).

The serious install shape is port 443 with one hostname and its wildcard — `space.example.com` for the API and the web app, `*.space.example.com` for the groups' content — a real certificate via `--cert <pem> --key <pem>` covering both names (or `--cert`/`--key` for the hostname plus `--group-certificate`/`--group-private-key` for a separate `*.space.example.com` leaf, presented to the group hosts by SNI), and `--host 0.0.0.0` (or the interface that faces your clients). Such a server hands out no fingerprint, so a certificate renewal never locks devices out. Advertise the hostname with `--origin https://space.example.com`: share-login and invite links carry it instead of whatever address the minting wallet happens to use, and the group hosts hang under it. Group hosts reached from another machine need `--origin`: without it they are `<group>.localhost:<port>`, which only this machine resolves. Clients learn the content base (`space.example.com`, with the port when it isn't 443) from `GET /v1/server`. Binding 443 needs the usual privilege arrangement for your platform (setcap, launchd, or a port redirect); that mechanics is out of scope here.

On a home LAN the space's name must resolve together with its subdomains, which an mDNS name does not: `mac.local` resolves, `team.mac.local` never does. Three ways work. [sslip.io](https://sslip.io) names every address and all its subdomains, so `--origin https://192-168-1-5.sslip.io:5530` needs no setup (it does need outbound DNS, and the certificate stays the self-signed one, pinned by fingerprint, with a browser interstitial per host). A domain you own takes a wildcard DNS record pointing at the machine, and then a real wildcard certificate. On Tailscale, grant the machine the `dns-subdomain-resolve` node attribute in the tailnet policy so MagicDNS resolves `*.<machine>.<tailnet>.ts.net`, and pass `--origin https://<machine>.<tailnet>.ts.net:5530`; or use sslip.io with the machine's tailnet address.

A link to a group's page is written on the space's host, `https://<host>/<path>?group=<group>`, and a `shared` page drops the `group` parameter: the web app opens it in the right group with the viewer's own device key. A group host that gets a top-level browser navigation it has no read cookie for answers `303` to that link, so a raw `<group>.<host>` URL pasted into a browser lands in the web app too.

## Authentication

Without `--dev`, the space's host admits enrolled devices only. Every `/v1` request needs a bearer assertion signed by an enrolled device key; an anonymous one gets `401 unauthorized`, `this space admits enrolled devices only`. A few routes carry their own credential or are public discovery and pass the wall: `GET /v1/machine/connect` and `GET /v1/machine/challenge` (a machine's signed challenge), `POST /v1/enroll/consume` (the join token it burns), `POST /v1/enroll/share-login` and `GET /v1/enroll/share-login/challenge` (an enrolled key's signed challenge), `GET /v1/server` and `GET /v1/groups`. The embedded web app's static GETs pass too. The group hosts have their own wall: content reads need a read cookie minted from an enrolled device, unless the server runs with `--public-read`, which opens content reads of `shared.<host>` to anyone. Every other group host still needs a read cookie, and writes and the API stay walled.

`--dev` drops both walls: every caller acts as the space owner. With the
default `--host 127.0.0.1` that is anyone on this machine; don't combine it
with an exposed `--host`.

The first device of a space is enrolled offline, from the space folder itself
(possession of the folder is root), with the server stopped:

```bash
wuhu serve ~/my-space --host 0.0.0.0 --origin https://space.example.com:5530
# ctrl-c once it is up: the first boot records the origin and TLS certificate
wuhu user add --space ~/my-space --name me          # prints the account id; the first account is admin
wuhu user invite --space ~/my-space <account-id> > invite.txt
wuhu serve ~/my-space --host 0.0.0.0 --origin https://space.example.com:5530
```

The invite link (`https://<origin>/_/enroll#token=jt_…&space=spc_…&fp=sha256:…`)
carries the fingerprint of the generated certificate recorded at boot (none
under `--cert`/`--key`) and expires after an hour
(`--ttl <seconds>`). Without `--origin`, pass `--server https://<host>:<port>` to
`user invite`. On the device, enroll and pin:

```bash
wuhu login < invite.txt
wuhu use space.example.com:5530
```

`wuhu login` records a delivered fingerprint as a pin (a link without one
drops a pin left by an earlier enrollment once the server passes system trust), generates this device's key for
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
[wuhu-cli.md](wuhu-cli.md#machines-exec-secrets).

## Where to go next

- [wuhu-cli.md](wuhu-cli.md) — the complete verb reference.
- [http-api.md](http-api.md) — the `/v1` routes.
- [Space tools](../packages/wuhu-core/Targets/SpaceToolReference/Tests/reference/README.md) — one page per tool behind `POST /v1/tools/:name`.
- [wire-schemas.md](wire-schemas.md) — the generated JSON Schemas of every request and response.
