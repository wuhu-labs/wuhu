# SSHMachine

Commands over SSH as Wuwei jobs.

- `SSHHost`, one job per host: it holds the connection and runs the requests mailed to it one at a time. Taking a request deletes its mail row, and the output gate makes that durable before the command leaves, so no request runs twice. After a minute without requests it closes the connection and hibernates.
- `SSHCall<Caller>`, one job per command: it asks the host and replies to the caller exactly once, with `.output`, `.unreachable` (the command did not run) or `.unknown` (it may have run: the connection broke, or no answer came before the timeout). A command that is not `retrySafe` goes to the host once, ever; a retry-safe one is sent again after a failover or a broken connection, until its deadline.
- `SSHClient.openSSH` is the system `ssh` with one ControlMaster per host, so hosts, users and keys come from the ssh config. A command that exits 255 reads as a broken connection.
