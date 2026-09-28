# Wuhu

Wuhu is an LLM agent workspace for individuals and small teams. A **space** is one folder served by one space server: files, tables, revisions, conversations and LLM sessions in one SQLite database. People reach it through the `wuhu` CLI and the web app the server embeds; agents living in the space use the same tools.

This repository holds the space server and the `wuhu` CLI, which ship as one binary, plus the web app it serves. The native macOS and iOS app is a separate product and is closed source.

The API is pre-1.0 and may change with any release.

## Build

You need [Bazelisk](https://github.com/bazelbuild/bazelisk), [Deno](https://deno.com), and either macOS 26 with Xcode 26.4 or Linux with Swift 6.3.

```bash
bazel build //packages/wuhu-core:wuhu
install -m 755 .bazel/bin/packages/wuhu-core/wuhu ~/.local/bin/wuhu
bazel test //...
```

The build compiles the web app and embeds it in the binary; that step fetches its lockfile-pinned npm dependencies.

## Run

```bash
wuhu serve ~/my-space --dev
```

Open `https://localhost:5540/` for the web app, or pin the space from any folder and use the CLI:

```bash
wuhu use localhost:5540 --pin
wuhu write /notes/plan.md --body "# Plan"
wuhu ls /
```

The server binds `127.0.0.1` unless `--host` says otherwise, and `--dev` turns the auth wall off: anyone who can reach the port can do anything in the space. To expose a space, drop `--dev` and enroll devices; [Getting started](docs/getting-started.md) covers that, TLS, sessions and machines.

## Docs

- [Getting started](docs/getting-started.md): build, first space, transport, authentication, sessions.
- [CLI reference](docs/wuhu-cli.md): every `wuhu` verb.
- [HTTP API](docs/http-api.md): the `/v1` routes.
- [Space tools](packages/wuhu-core/Targets/SpaceToolReference/Tests/reference/README.md): one generated page per tool behind `POST /v1/tools/:name`.
- [Wire schemas](docs/wire-schemas.md): the generated JSON Schemas of every request and response.

## Contributing

This project is open source, closed to contributions: pull requests are not accepted.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
