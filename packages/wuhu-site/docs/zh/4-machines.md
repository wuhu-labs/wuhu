---
title: 机器
---
# 机器

一台机器就是你的 agent 能在上面干活的电脑：跑命令、读写文件。它可以是服务器所在的那台主机，也可以是任何别的 Mac 或者 Linux 机器。

## 接入一台

在已经登录的 CLI 上注册机器：

```sh
wuhu machine add --name mini
```

它会打印一枚一次性的加入 token（`jt_...`）和加入命令；如果服务器用的是 Wuhu 自己生成的证书，加入命令里还会带上它的证书指纹。把这枚 token 放到那台机器上的一个文件里，然后在装好 `wuhu` 的那台机器上执行：

```sh
wuhu machine join https://example.wuhu:5530 sha256:<fingerprint> --name mini < token
wuhu machine run
```

用你自己的证书（`--cert`）时，就没有指纹要传。token 从 stdin 进去，所以不会出现在你的 shell 历史里。

`machine join` 把那台机器的密钥和 runner 设置存在它的 `~/.wuhu/machine/` 下。`machine run` 就是 runner。跟 GitHub Actions self-hosted runner 一样，它主动连到你的服务器上，断了会自己重连，你不用在机器上开任何端口。它跑在前台；要常驻就交给 launchd、systemd，或者你自己顺手的办法。

在 macOS 上，如果服务器在局域网里，runner 需要「本地网络」权限。launchd 不会弹这个提示，所以先手动跑一次并允许它。如果 launchd 起的 runner 还是连不上服务器，用 tmux 会话跑也行。

## 信任

runner 是拿运行它的那个系统账号的权限去做 agent 让它做的事。Wuhu 不加沙箱，也不做逐条审批。接入之前先把那个账号定好：

- 用你自己的账号，就能访问你自己的所有东西；
- 想圈起来，就用一个单独的系统账号、虚拟机或者容器。

## 谁能用它

机器属于某个组，一开始在添加它的人的个人组里。任何能读那个组的组，里面的 agent 都能用它。所以你个人组里的机器只有你能用；把它移到 `shared`，所有人的 agent 就都能用：

```sh
wuhu machine move mini --group shared
```

移动需要两个组的 admin 权限。

## agent 命令里的 CLI

agent 在机器上跑命令时，这条命令启动的任何 `wuhu` 二进制都以这个 agent 的身份行事：不管在不在 PATH 里，用 `~/.wuhu/bin/wuhu` 这样的完整路径也行，机器上不用登录任何东西。所以 agent 和它的脚本可以像你一样，在 shell 里操作空间。

它有的就是这个 agent 自己的权限，在 agent 所在的组里：文件、表格、查询、消息、会话、机器上的命令。属于人的东西一律拒绝：登录、账号、密钥、模型凭证、添加机器。命令结束，这份权限也就结束了。

在 agent 的命令之外，比如你自己的终端或者你自己的 `wuhu exec`，CLI 照常用你自己的登录。

如果你在那台机器上登录过 CLI，agent 可以主动选择改用你的登录：`WUHU_IDENTITY=wallet wuhu ...`。这样命令就以你的身份行事，连的是你那个登录指向的空间，agent 要碰另一个空间也是这么做。每条这样的命令 CLI 都会说一声。要主动选择，是为了不会不小心发生，不是一道围栏：在你登录过的机器上，agent 想以你的身份行事就能做到。

## 给 agent 的说明

每台机器在空间里有一个说明文件夹，`/_/machines/<name>/`。在里面放一个 `AGENTS.md`，技能放到 `.agents/skills/` 下，就可以告诉 agent 该怎么在这台机器上干活：代码在哪、用哪个 checkout、什么别碰。agent 第一次碰这台机器的时候会读它们。谁都可以编辑。

## 机器上的密钥

机器上的命令可以从机器所在的组拿密钥，比如一个部署用的 token。那个组的 admin 在该组里用 `wuhu secret set <NAME> < value` 把它存到服务器上（见[密钥](/guide/zh/5-models.md#密钥)）。

命令按名字要它，拿到的是一个环境变量：`wuhu exec --secret TOKEN=DEPLOY_TOKEN ...`，agent 在脚本里也一样。agent 从来看不到这个值，输出里它也会被打码。不管谁来跑命令，一台机器只拿得到它自己那个组的密钥。
