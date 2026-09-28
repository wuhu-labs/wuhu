# FetchAsyncHTTPClient

`FetchClient.asyncHTTPClient(_:timeout:)` adapts an existing AsyncHTTPClient client without taking ownership of its lifecycle. Request deadlines, response streaming, and transport-error classification remain independent of connection health checks.

## Opt-in HTTP/2 health checks

Call `HTTPClient.Configuration.enableHTTP2HealthChecks(idleInterval:acknowledgementTimeout:)` before constructing the client. Both intervals must be positive; defaults are 30 seconds and 10 seconds. The helper preserves the existing HTTP/2 connection initializer and propagates its failure. Repeated configuration installs one detector per connection, using the most recently supplied intervals. HTTP version negotiation, HTTP/1 connections, stream initializers, and request deadlines are unchanged.

The detector attaches to each physical HTTP/2 parent channel, after its HTTP/2 codec and before AHC's stream accounting and multiplexer. It only probes connections with active streams. The first active stream starts a quiet interval; any inbound HTTP/2 frame postpones the next probe. Outbound traffic does not establish peer liveness. Connections with no active streams are left to AHC's normal pool-idle policy.

After the quiet interval, the detector sends one stream-zero PING with a connection-local nonce. It arms the acknowledgement deadline before issuing the write, so a blocked write cannot disable detection. Only an ACK with that outstanding nonce satisfies the probe; unrelated traffic, non-ACK PINGs, and old or incorrect nonces do not extend its deadline. A successful ACK starts another quiet interval. Completion of the last active stream cancels probing. Connection teardown cancels all scheduled work.

A write failure or acknowledgement timeout closes the parent channel, failing its active streams and allowing AHC to remove that physical connection from the pool. The detector never creates request streams, changes pool reservations, retries requests, or interprets response status. Callers retain responsibility for retries and inference-progress watchdogs. A PING ACK demonstrates responsiveness of the HTTP/2 peer, not progress of an inference worker behind a terminating proxy.

The `FetchAsyncHTTPClient.HTTP2Health` logger records PING sends/ACKs at info, retirement at warning, GOAWAY error code and last-stream ID at notice, and connection/stream lifecycle at debug. Logs include a connection identifier and do not include headers or payloads. GOAWAY frames and stream lifecycle events are observed and forwarded unchanged; this helper does not change AHC's GOAWAY handling.

Wuhu's inference client opts in using the defaults. Its other HTTP clients do not.
