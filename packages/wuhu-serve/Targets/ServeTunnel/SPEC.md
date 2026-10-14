# ServeTunnel

ServeTunnel runs a Serve Handler on the serving end of FetchTunnel, with the same framing, limits and lifecycle. It is a thin adapter and knows nothing about machines, authentication, identity or processes. A Handler receives a complete capped request and returns an ordinary Response. A response body is capped and collected before transmission. The caller owns the serving task and transport lifecycle. Applications authenticate the upgrade and authorize each addressed request outside these packages.
