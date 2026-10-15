# Fetch

`Body.isBuffered` identifies bodies backed entirely by in-memory chunks, including empty, byte, string and JSON bodies. Inspecting it does not consume or resolve the body. Stream-backed bodies report false even when their length is known or their producer is replayable. Transport adapters can use this distinction to send already-buffered bytes without introducing an asynchronous request producer; reading those bytes still consumes the body normally.
