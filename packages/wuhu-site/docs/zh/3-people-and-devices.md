---
title: 人和设备
---
# 人和设备

没有密码。你每登录一台设备，那台设备就有自己的一把密钥：iPhone、iPad、Mac 和 Vision Pro 上存在 Keychain 里，网页版存在浏览器的存储里，CLI 存在 `~/.wuhu` 里。一台设备只用一条一次性邀请链接登录一次。

## 第一个人

先用 `--origin` 启动一次服务器，让它把文件夹建出来，并记下邀请链接要带的地址和证书。然后停掉它，运行：

```sh
wuhu user add --space <folder> --name alice --admin
wuhu user invite --space <folder> <account-id>
```

`user add` 会打印新账号的 id。`user invite` 打印一条一次性链接，有效一小时（用 `--ttl <seconds>` 改）。链接里带着服务器的地址，如果服务器用的是 Wuhu 自己生成的证书，还带上它的指纹，所以打开这条链接的设备从第一次连接起就信任对的服务器。

再把服务器启动起来，在 App 或者网页版里打开这条链接，也可以交给 CLI：`wuhu login < invite-link`。别外传：谁先打开谁就进去了。

带上 `--space` 时，这些命令直接操作文件夹，所以必须先把服务器停掉。只有两种时候需要这样：第一个人，因为还没有人能登录；以及你万一设备全丢了之后的回家路：`wuhu user reset --space <folder> <account-id>` 会把那个账号的所有设备登出，账号本身保留。然后再发一条新邀请。

## 更多设备

在一台已经登录的设备上，`wuhu share-login` 可以给你自己的另一台设备生成一条邀请。默认有效期十分钟，最长三天。

那台设备得能连到服务器：同一个 Wi-Fi、Tailscale，或者一个公网地址。见[运行服务器](/guide/zh/2-running-the-server.md)。

## 更多人

admin 在任何一个已登录的 CLI 上加人，服务器不用停：

```sh
wuhu user add --name bob
```

它会打印 bob 的账号 id 和一条一次性邀请链接，有效一小时。把链接发给他。过期了或者弄丢了，`wuhu user invite <account-id>` 再生成一条。

`wuhu user list` 列出所有人，`wuhu user remove <account-id>` 把某个人删掉。

## 组

空间里所有东西都活在某个组里：文档、表格、agent、机器。

- **`shared`** 放所有人都看得到的东西。每个人都是成员。
- **个人组**是给每个人建的。只有本人在里面。它的 id 是建账号时抽出来的一个词组名，比如 `river-lamp-otter`，不是你给的 `--name`；平时很少用到。

个人组可以读 `shared`，`shared` 读不了个人组。所以你个人组里的 agent 能读共享文档，别人的 agent 读不到你的。

Agent 在它被创建的那个组里干活。要碰别的组的文件得用完整地址，`wuhu://shared.localspace/notes/plan.md`，而且只在它的组能读那个组的时候才行。

在 CLI 里，用 `--group <id>`、环境变量 `WUHU_GROUP` 或者 `wuhu group use <id>` 选组。不选就在 `shared` 里。`wuhu group list` 列出你能用的组。

## 管理员

`shared` 的 admin 可以加人、删人，而且至少永远有一个 admin。第一个账号就是。想让别人也是 admin，`user add` 时加 `--admin`，或者之后跑 `wuhu user admin <account-id>`。每个人都是自己个人组的 admin。
