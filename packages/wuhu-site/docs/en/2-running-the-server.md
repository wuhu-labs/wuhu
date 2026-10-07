---
title: Running the server
---
# Running the server

`wuhu serve <folder>` runs a space. It creates the folder on first start. It runs in the foreground; daemonize it with launchd, systemd or whatever you use.

## How a space is addressed

A space lives at one base name, say `example.wuhu`. The base name serves the API and the web app.

Each group gets a host of its own under it, `<group>.example.wuhu`, which serves that group's pages and files: `shared.example.wuhu` for the shared group, plus one for each person's personal group. Those pages are HTML that people and agents write, so they're kept apart from the API on origins of their own. A page can't act with your session.

You never sign in to a group host yourself. The apps get a read cookie for each group host from the API when they open it.

## Decide before you deploy

- **A name.** One domain and all its subdomains. A `.local` name or a bare IP won't do, but there are workarounds; see [Picking a name](#picking-a-name).
- **A certificate.** Self-signed, your own, or behind a proxy. See [Certificates](#certificates).
- **Who should reach it.** Just this computer, your home network, your tailnet, or the internet.

## Picking a name

Bonjour names like `mac-mini.local` don't do subdomains, so `alice.mac-mini.local` never resolves. Instead:

- **An sslip.io name.** `https://192-168-1-5.sslip.io:5530` resolves to `192.168.1.5`, and so does every name under it. Only the DNS lookup goes to sslip.io; your traffic stays on your network. Give the server a fixed LAN address (a DHCP reservation on your router).
- **Tailscale.** The same trick with the server's Tailscale address, e.g. `https://100-101-102-103.sslip.io:5530`, reaches it from anywhere on your tailnet.
- **A domain you own**, with `example.wuhu` and a wildcard `*.example.wuhu` pointing at the server's address, so groups added later resolve too. Only one label is recognized: `alice.example.wuhu`, not `a.b.example.wuhu`.
- **A Cloudflare Tunnel**, to reach it from the internet without opening a port. Cloudflare terminates TLS, so this is the proxy setup below: run with your own certificate and set `--origin` to the public name without a port. Cloudflare's free certificate covers one level of wildcard, so a base at the zone apex (`example.com`, groups at `*.example.com`) works on it; a deeper base like `wuhu.example.com` needs a paid certificate for `*.wuhu.example.com`.

## Certificates

Wuhu only speaks TLS; there is no plain-HTTP mode. Pick one of three setups:

- **Self-signed** (the default). Generated into `<folder>/tls/`, good for a year, and served on every host. Invites carry its fingerprint, and the CLI and the apps pin it, so they accept it under any name, an sslip.io one included. Browsers don't know the pin and warn. It is regenerated within seven days of expiry, which changes the fingerprint, and every client then has to trust it again.
- **Your own**: `--cert <pem> --key <pem>`, e.g. a Let's Encrypt certificate for `example.wuhu` and `*.example.wuhu`. Invites then carry no fingerprint: devices check the certificate the normal way, so renewals just work. A certificate from your own CA works too, once your devices trust that CA.
  - Or keep two: `--group-certificate` / `--group-private-key` serve a separate certificate on the group hosts.
- **Behind a load balancer, reverse proxy or tunnel**: the upstream is always TLS. With your own certificate, the proxy may terminate TLS with any certificate your devices trust; keep the host name and support WebSockets and server-sent events. With the self-signed one, pass TLS through as a stream (TCP/L4), because devices pin it. We haven't tested a proxy recipe end to end yet.

## Starting it

- `--origin` is the name, e.g. `--origin https://example.wuhu:5530`. Invites carry it, so set it from the first start, and set it to the address people actually use, not the internal one. Without it the address is `https://localhost:5530`, which is fine for trying Wuhu alone on one computer.
- The server listens on one HTTPS port, `--port`, default `5530`.
- It binds to `127.0.0.1` by default. Use `--host 0.0.0.0` so other devices can reach it.

## Keeping it running

- Run it under whatever manages services on the host: launchd, systemd, a container, a tmux session.
- Start it through `~/.wuhu/bin/wuhu`. That path never changes, so an upgrade takes effect on the next restart, and macOS permissions you granted it survive upgrades.
- macOS asks whether `wuhu` may use the local network the first time a device on your LAN connects. Allow it.

## Upgrading

- `wuhu upgrade` downloads the newest build on your lane (`dev`, `beta` or `release`) and puts it in place at `~/.wuhu/bin/wuhu`, keeping the last few versions beside it. It does not restart anything, so restart the server and your runners yourself. `wuhu upgrade --rollback` goes back one version.
- Stop the server and back up the folder before upgrading. See [Your data](/guide/6-your-data.md).

## Other flags

- `--public-read`: anyone can read the `shared` group's pages and files at `shared.example.wuhu` without signing in. Personal groups stay private. Writes still need an account.
- `--dev`: turns off sign-in entirely. For development on your own machine only.
