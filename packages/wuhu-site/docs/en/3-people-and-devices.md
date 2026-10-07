---
title: People and devices
---
# People and devices

There are no passwords. Each device you sign in from gets its own key: in the Keychain on iPhone, iPad, Mac and Vision Pro, in the browser's storage for the web app, and in `~/.wuhu` for the CLI. A device signs in once, with a one-time invite link.

## The first person

Start the server once with `--origin`, so it creates the folder and records the address and certificate that invites carry. Then stop it and run:

```sh
wuhu user add --space <folder> --name alice --admin
wuhu user invite --space <folder> <account-id>
```

`user add` prints the new account's id. `user invite` prints a one-time link, good for an hour (`--ttl <seconds>` to change that). It carries the server's address and, with the certificate Wuhu generated, its fingerprint, so the device that opens it trusts the right server from the first connection.

Start the server again and open the link in the app or the web app, or give it to the CLI: `wuhu login < invite-link`. Keep it private: whoever opens it first gets in.

With `--space`, these commands work on the folder directly, which is why the server has to be stopped. That's only needed for the first person, since nobody can sign in yet, and as your way back in if you lose every device: `wuhu user reset --space <folder> <account-id>` signs out every device of that account and keeps the account. Then make a new invite.

## More devices

From a device that's already signed in, `wuhu share-login` makes an invite for another device of yours. It lasts ten minutes by default, three days at most.

The device has to reach the server: the same Wi-Fi, Tailscale, or a public address. See [Running the server](/guide/2-running-the-server.md).

## More people

An admin adds people from any signed-in CLI, with the server running:

```sh
wuhu user add --name bob
```

It prints bob's account id and a one-time invite link, good for an hour. Send him the link. If it expires or gets lost, `wuhu user invite <account-id>` makes a new one.

`wuhu user list` shows everyone, and `wuhu user remove <account-id>` removes someone.

## Groups

Everything in a space lives in a group: documents, tables, agents, machines.

- **`shared`** holds what everyone sees. Everyone is a member.
- **A personal group** is created for each person. Only that person is in it. Its id is a word name drawn when the account is created, like `river-lamp-otter`, not the `--name` you gave; you rarely need it.

A personal group can read `shared`; `shared` can't read a personal group. So an agent in your personal group can read the shared documents, and nobody else's agents can read yours.

An agent works in the group it was created in. It reaches another group's files by full address, `wuhu://shared.localspace/notes/plan.md`, and only when its group can read that one.

In the CLI, pick your group with `--group <id>`, the `WUHU_GROUP` environment variable, or `wuhu group use <id>`. Otherwise you're in `shared`. `wuhu group list` shows the groups you can use.

## Admins

An admin of `shared` can add and remove people, and there is always at least one admin. The first account is one. Pass `--admin` to `user add`, or run `wuhu user admin <account-id>` later, to make someone else one too. Everyone is the admin of their own personal group.
