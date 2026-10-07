---
title: Machines
---
# Machines

A machine is a computer your agents can work on: run commands, read and write files. It can be the server's own host or any other Mac or Linux box.

## Joining one

From a signed-in CLI, register the machine:

```sh
wuhu machine add --name mini
```

It prints a one-time join token (`jt_...`) and the join command, with the server's certificate fingerprint if it runs the certificate Wuhu generated. Put the token in a file on the machine, then, with `wuhu` installed there:

```sh
wuhu machine join https://example.wuhu:5530 sha256:<fingerprint> --name mini < token
wuhu machine run
```

With your own certificate (`--cert`) there's no fingerprint to pass. The token goes in on stdin so it never shows up in your shell history.

`machine join` stores the machine's key and runner settings in `~/.wuhu/machine/` on that box. `machine run` is the runner. Like a GitHub Actions self-hosted runner, it dials out to your server and reconnects on its own, so you don't open any port on the machine. It runs in the foreground; daemonize it with launchd, systemd or whatever you use.

On macOS, if the server is on your local network, the runner needs the Local Network permission. launchd won't show the prompt, so run it once by hand and allow it first. If a launchd runner still can't reach the server, a tmux session works.

## Trust

The runner does what agents ask with the permissions of the OS user that runs it. Wuhu adds no sandbox and no per-command approval. Choose that user before you join:

- your own account, for full access to your own stuff;
- a separate OS account, a VM or a container, to fence it in.

## Who can use it

A machine belongs to a group, and it starts in the personal group of whoever added it. Agents in any group that can read that group can use it. So a machine in your personal group is yours alone; move it to `shared` and everyone's agents can use it:

```sh
wuhu machine move mini --group shared
```

Moving needs admin rights in both groups.

## The CLI inside an agent's command

When an agent runs a command on a machine, any `wuhu` binary that command starts acts as that agent: on PATH or at a full path like `~/.wuhu/bin/wuhu`, with nothing signed in on the machine. So agents and their scripts can drive the space from a shell the same way you do.

It has the agent's own rights, in the agent's group: files, tables, queries, messages, sessions, commands on machines. Whatever belongs to people is refused: signing in, accounts, keys, model credentials, adding machines. The access ends with the command.

Outside an agent's command, in your own terminal or your own `wuhu exec`, the CLI uses your own sign-in as usual.

If you've signed in to the CLI on that machine, an agent can opt in to your sign-in instead: `WUHU_IDENTITY=wallet wuhu ...`. The command then acts as you, on whatever space that sign-in points at, which is also how an agent reaches another space. The CLI says so on every such command. It's opt-in so it never happens by accident, not a fence: on a machine where you've signed in, agents can act as you when they mean to.

## Notes for agents

Each machine has a notes folder in the space, `/_/machines/<name>/`. Put an `AGENTS.md` there, and skills under `.agents/skills/`, to tell agents how to work on that machine: where the code lives, which checkout to use, what not to touch. An agent reads them the first time it touches the machine. Anyone can edit them.

## Secrets on the machine

A command on a machine can get secrets from the machine's group, e.g. a deploy token. An admin of that group stores one on the server with `wuhu secret set <NAME> < value`, acting in that group (see [Secrets](/guide/5-models.md#secrets)).

A command then asks for it by name and gets it as an environment variable: `wuhu exec --secret TOKEN=DEPLOY_TOKEN ...`, and agents do the same from their scripts. The agent never sees the value, and it's masked in the output. A machine only ever gets its own group's secrets, whoever runs the command.
