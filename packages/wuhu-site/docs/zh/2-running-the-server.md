---
title: 运行服务器
---
# 运行服务器

`wuhu serve <folder>` 运行一个空间。首次启动时它会把这个文件夹建出来。它跑在前台；要常驻就交给 launchd、systemd，或者你自己顺手的办法。

## 空间怎么寻址

一个空间住在一个基础域名下，比如 `example.wuhu`。基础域名提供 API 和网页版应用。

每个组在它下面有自己的主机名 `<group>.example.wuhu`，提供那个组的页面和文件：共享组是 `shared.example.wuhu`，另外每个人的个人组各有一个。这些页面是人和 agent 写的 HTML，所以它们和 API 分开，各自是独立的 origin。页面没法拿你的会话去做事。

组的主机名你自己从来不用登录。App 打开某个组的主机名时，会先从 API 拿到那个组主机名的读 cookie。

## 部署之前先定好

- **一个名字**。一个域名，加上它下面所有的子域名。`.local` 名字和裸 IP 都不行，不过有变通办法，见[选一个名字](#选一个名字)。
- **一张证书**。自签、你自己的，或者挂在代理后面。见[证书](#证书)。
- **谁该连得上**。只有这台电脑、家里的网络、你的 tailnet，还是整个互联网。

## 选一个名字

Bonjour 名字（比如 `mac-mini.local`）不支持子域名，所以 `alice.mac-mini.local` 永远解析不了。可以这样：

- **用 sslip.io 的域名**。`https://192-168-1-5.sslip.io:5530` 会解析到 `192.168.1.5`，它下面的任何名字也一样。走 sslip.io 的只有 DNS 查询，流量还是留在你自己的网络里。给服务器一个固定的局域网地址（在路由器上做 DHCP 保留）。
- **Tailscale**。同样的办法，换成服务器的 Tailscale 地址，比如 `https://100-101-102-103.sslip.io:5530`，你在自己的 tailnet 里从哪都能连到。
- **你自己有的域名**，把 `example.wuhu` 和泛解析 `*.example.wuhu` 指到服务器的地址，以后新增的组也就能解析了。只认一级标签：`alice.example.wuhu` 可以，`a.b.example.wuhu` 不行。
- **Cloudflare Tunnel**，不开端口也能从公网连上来。TLS 由 Cloudflare 终结，所以这就是下面说的代理方案：用你自己的证书启动，`--origin` 设成不带端口的公网名字。Cloudflare 的免费证书只覆盖一级泛域名，所以基础域名放在根域上（`example.com`，组在 `*.example.com`）就能用；更深一层的，比如 `wuhu.example.com`，需要为 `*.wuhu.example.com` 买付费证书。

## 证书

Wuhu 只说 TLS，没有纯 HTTP 模式。三种方案挑一个：

- **自签证书**（默认）。生成在 `<folder>/tls/` 下，有效期一年，所有主机名都用它。邀请链接里带它的指纹，CLI 和各个 App 会把它 pin 住，所以不管用什么名字——包括 sslip.io 的——它们都认。浏览器不知道这个 pin，会报警告。它会在到期前七天内自动重新生成，指纹随之改变，之后每个客户端都得重新信任一次。
- **你自己的证书**：`--cert <pem> --key <pem>`，比如给 `example.wuhu` 和 `*.example.wuhu` 签的 Let's Encrypt 证书。这时邀请链接里不带指纹：设备按常规方式校验证书，所以续期之后照样能用。你自己 CA 签的证书也行，只要你的设备信任这个 CA。
  - 也可以两张都用：`--group-certificate` / `--group-private-key` 给组的主机名单独提供一张证书。
- **挂在负载均衡、反向代理或者隧道后面**：上游永远是 TLS。用你自己的证书时，代理可以用任何设备信任的证书来终结 TLS；保留主机名，并且支持 WebSocket 和 server-sent events。用自签证书时，把 TLS 当流（TCP/L4）透传，因为设备把它 pin 住了。代理这套配置我们还没端到端测过。

## 启动

- `--origin` 就是那个名字，例如 `--origin https://example.wuhu:5530`。邀请链接里带的就是它，所以第一次启动就要设好，而且要设成大家实际用的地址，不是内网那个。不传时地址是 `https://localhost:5530`，只在一台电脑上自己试试 Wuhu 的话够用。
- 服务器只监听一个 HTTPS 端口，`--port`，默认 `5530`。
- 默认绑定 `127.0.0.1`。想让别的设备也能连上来，用 `--host 0.0.0.0`。

## 让它一直跑着

- 交给主机上管服务的东西：launchd、systemd、容器、一个 tmux 会话，都行。
- 用 `~/.wuhu/bin/wuhu` 启动。这个路径永远不变，所以升级会在下次重启时生效，你给它的 macOS 权限升级后也还在。
- 局域网里有设备第一次连过来时，macOS 会问 `wuhu` 能不能使用本地网络。允许它。

## 升级

- `wuhu upgrade` 下载你所在通道（`dev`、`beta` 或 `release`）的最新构建，放到 `~/.wuhu/bin/wuhu` 这个位置，旁边留着最近几个版本。它不重启任何东西，服务器和 runner 要你自己重启。`wuhu upgrade --rollback` 退回上一个版本。
- 升级前先停掉服务器、备份文件夹。见[你的数据](/guide/zh/6-your-data.md)。

## 其他参数

- `--public-read`：不用登录，任何人都能在 `shared.example.wuhu` 上读 `shared` 组的页面和文件。个人组依然私有。写入还是需要账号。
- `--dev`：完全关掉登录。只在自己的机器上开发时用。
