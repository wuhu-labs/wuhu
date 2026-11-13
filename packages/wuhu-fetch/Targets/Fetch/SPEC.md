# Fetch

`Body.isBuffered` identifies bodies backed entirely by in-memory chunks, including empty, byte, string and JSON bodies. Inspecting it does not consume or resolve the body. Stream-backed bodies report false even when their length is known or their producer is replayable. Transport adapters can use this distinction to send already-buffered bytes without introducing an asynchronous request producer; reading those bytes still consumes the body normally.

`Body.endsByItself` says whether the producer reaches the end of the body without the client: buffered bytes do, a streamed body does not. A host that re-serves a body through its own accounting wraps it with `rethreaded(over:)`, which keeps that answer, the length and the content type while the wrapped bytes go through the host's own producer; a rethreaded body is never replayable.
