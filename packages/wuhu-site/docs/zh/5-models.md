---
title: 模型和凭证
---
# 模型和凭证

Wuhu 自己不带模型。你在服务器所在的主机上接上你自己的账号，空间里所有 agent 都用它。

## 接入账号

在服务器所在的主机上，用跑服务器的那个用户运行：

- `wuhu auth login codex`：用你的 ChatGPT 账号登录。它会给你一个码，在浏览器里确认。
- `wuhu auth set <provider> < key.txt`：从 stdin 给一个 API key，目录里任何一个 provider，或者下面说的搜索、图片、转写 provider 都行。

`wuhu auth list` 看已经接了哪些；`wuhu auth remove <provider>` 删掉一个。服务器上如果有 `ANTHROPIC_API_KEY` 这样的环境变量，它会盖过存下来的 key。

Key 存在服务器所在主机的 `~/.wuhu/credentials/<space-id>.json` 里。不在空间文件夹里，任何客户端也拿不到。

它们属于整个空间，不属于某个组：所有人的 agent 用的是同一批账号。如果朋友和你共用一个空间，花的就是你的订阅。

## 模型目录

`shared` 组里的 `/models.json` 列出了各个 provider 和它们的模型：API 风格、base URL、每个模型的上下文和输出上限，以及可选的 reasoning effort。你开 agent 的时候从里面挑。

它自带 Anthropic（`anthropic`）、OpenAI（API key 用 `openai`，ChatGPT 订阅用 `codex`）和 DeepSeek。它就是一个普通文档，所以你或者 agent 都能加一个 provider 或模型。provider 必须会说 Wuhu 支持的某种 API 风格：Anthropic Messages、OpenAI Responses 或者 ChatGPT Codex。只有 OpenAI Chat Completions 不够，所以一些本地服务器用不了。

`wuhu models update` 会把 CLI 自带的清单并进去，不会覆盖你改过的东西。在 `shared` 里跑：`wuhu --group shared models update`。

## 搜索、图片和转写

agent 能搜网页、生成和编辑图片、转写音频，App 的语音输入也用转写。CLI 里也有：`wuhu web-search`、`wuhu image`、`wuhu transcribe`。

如果你用 `wuhu auth login codex` 登录过，这三样已经能用了，走的是你的 ChatGPT 账号。不用再配别的。

想用别的 provider，就在 `shared` 里写一个 `/capabilities.json`。每种能力列出你有的 provider，以及当前用哪一个：

- `web_search`：`codex`、`brave`、`exa`
- `image`：`codex`、`openai-images`、`dashscope`（通义千问）
- `transcription`：`codex`、`openai-audio`、`dashscope`（通义千问）

```json
{
  "web_search": {
    "active": "brave",
    "providers": { "brave": { "dialect": "brave" } }
  }
}
```

然后用 provider 的名字存 key：`wuhu auth set brave < key.txt`。没写的能力继续走 Codex。写了但没配好的会直接报错，不会退回 Codex。

## 密钥

agent 的脚本和命令也能用密钥，比如某个 web 服务的 token。这些是按组分的，和上面的模型 key 分开放。

组的 admin 在那个组里（`--group <id>`，见[组](/guide/zh/3-people-and-devices.md#组)）用 `wuhu secret set <NAME> < value` 存一条；`wuhu secret list` 列出名字，`wuhu secret remove <NAME>` 删掉一条。它们存在服务器所在主机的 `~/.wuhu/secrets/<space-id>/<group>.json` 里。一个组永远看不到另一个组的。

脚本的密钥来自它的 agent 所在的组；值会被填进脚本对外的请求里，回来的内容里也会被打码。机器上的命令拿到的是机器所在组的密钥，作为环境变量。见[机器](/guide/zh/4-machines.md#机器上的密钥)。
