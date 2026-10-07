---
title: What Wuhu is
---
# What Wuhu is

Wuhu is a workspace you host yourself. Documents, tables and AI agents live in it together, and the agents can work on the computers you connect to it.

## The pieces

- **The server** is one binary, `wuhu`. You run it on a machine you own: a Mac mini at home, a Linux box, a VPS.
- **A space** is a folder that the server serves. Everything is in it: markdown documents, SQLite tables, conversations, agent sessions and their history. Back up the folder and you've backed up the space.
- **Agents** are AI sessions that live in the space. You talk to them in a Messages-like chat. Each has its own folder in the space. They can set timers and come find you on their own, read and write documents and tables, start other agents, and run commands on joined machines. They keep working after you close the app, and when the server restarts they come back on their own.
- **Machines** are computers you join to the space. Each runs a **runner**, `wuhu machine run`. Like a GitHub Actions self-hosted runner, it dials out to your server, so you don't open any port on that machine, and does what agents ask: run shell commands, read and write files.
- **Pages** are HTML files in the space. The server serves them as live web pages that read and write the space's data, so an agent can build you a small app by writing one file.
- **Clients**: native apps for iPhone, iPad, Mac and Vision Pro, a web app, and a CLI. All of them talk to your server and nothing else.
- **Models**: you bring your own, through a subscription or an API key: Claude, GPT, DeepSeek, Kimi, GLM, Qwen and others. Credentials stay on your server's host.

## Your data

The space is a folder on your disk. There's no Wuhu cloud and no account with us. The only outside party is the model provider you choose, which sees what your agents send it.

## Trust: we're in camp YOLO

Agents in a space can run any shell command on a joined machine, with whatever access the runner has. Wuhu adds no sandbox and no per-command approval. That is the point: they do real work on real computers.

So the runner's environment is your boundary. Pick it before you join a machine:

- your own OS account, for full access to your own stuff;
- a separate OS account, a VM or a container, if you want to fence it in;
- remember that anyone you add to the space can talk to its agents, and through them act on every joined machine.

## Alone or with friends

- **Alone**: one person, one group, and everything in it is yours.
- **With friends**: a shared group everyone sees, plus a personal group each. Agents and documents in a personal group stay private to that person.

## Next

1. [Running the server](/guide/2-running-the-server.md)
2. [People and devices](/guide/3-people-and-devices.md)
3. [Machines](/guide/4-machines.md)
4. [Models and credentials](/guide/5-models.md)
5. [Your data](/guide/6-your-data.md)
