---
title: Your data
---
# Your data

## What's in the folder

The space folder holds everything the space is:

- `space.sqlite`: documents, tables, conversations, agent sessions and their history, people, groups and machines;
- `objects/`: files larger than 256 KB;
- `tls/`: the self-signed certificate and its key;
- `web-push/`: the key browser notifications are sent with;
- `logs/`: one line per model call: tokens, timing, failures.

Documents are markdown and tables are SQLite, inside a database you can open yourself.

Every model call is also a row in the `inferences` table: who made it, which model, tokens in, cached and out, timing, errors. Query it like any table, e.g. `wuhu query "SELECT model, sum(output) FROM inferences GROUP BY model"`.

## What's outside it

A few things live in the home folder of the user that runs the server, on purpose, so that a copy of the space doesn't carry them:

- `~/.wuhu/credentials/<space-id>.json`: your model accounts and provider keys;
- `~/.wuhu/secrets/<space-id>/`: each group's secrets;
- on each machine, `~/.wuhu/machine/`: its key and runner settings.

## Backing up

Stop the server and copy the folder. Or take a filesystem snapshot (APFS, ZFS, Btrfs) of the whole folder while it runs. Don't copy a running server's folder file by file: the database is mid-write and the copy may not open.

Back up the credentials and secrets above separately, if you want them back without signing in again.

## Moving to another host

1. Stop the server.
2. Copy the space folder, plus `~/.wuhu/credentials` and `~/.wuhu/secrets` for that space.
3. Start it on the new host with the same `--origin`, and point DNS there.

Keep `tls/`, and devices and runners keep trusting it. Change the address and each device needs a new invite.

Never run two copies of one space at once. They'd share an identity and drift apart.

## Upgrades

Back up before you upgrade. If a new version needs a database migration it can't run on its own, the server refuses to start and names it.

## Who else sees it

- **Your model provider** sees what your agents send it: the conversation and whatever they read into it.
- **Search, image and transcription providers**, if you set them up, see the queries, prompts and audio sent to them.
- **Wuhu's notification relay**, for notifications on iPhone, iPad and Mac. Apple delivers push only on behalf of the app's developer, so your server hands each notification to our relay, `notifications.wuhu.ai`, which passes it to Apple: the title, the sender, a preview of the message, and ids to route it.
- **Your browser's push service**, for web notifications, straight from your server.
- **Downloads**: `wuhu upgrade` fetches builds from wuhu.ai.
- **Nobody else.** There's no Wuhu account and no cloud copy of the space.
