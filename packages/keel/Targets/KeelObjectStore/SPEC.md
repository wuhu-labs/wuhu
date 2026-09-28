# KeelObjectStore

Thin object-storage seam: put / get / head / delete / prefix-list
over opaque, slash-delimited keys. Two backends implement one `ObjectStore`
protocol; both pass the `ObjectStoreContract` suite in this target's tests.

## Keys

`ObjectKey` is a validated value type. A key is a non-empty, slash-delimited
relative path with no empty segments (rejects a leading `/`, a trailing `/`, and
`//`), no `.`/`..` segment (path-traversal gate for the filesystem backend), and
no control characters. `/` is a separator only — keys are opaque otherwise.

## SigV4

Signing is hand-rolled AWS Signature Version 4 (`AWS4-HMAC-SHA256`) over
swift-crypto's `HMAC<SHA256>` / `SHA256`. No AWS SDK. The signer is a set of pure
functions (`SigV4`) proven by golden vectors implemented by hand from stable AWS
sources (the aws-sig-v4-test-suite `get-vanilla` case and the S3 "GET Object" /
"PUT Object" authorization examples) — the vectors are knowledge, not vendored
code.

- Path encoding is single-pass for `service == "s3"` (`doubleEncode: false`), per
  the S3 exception to SigV4 path normalization.
- Payload signing is split by presence of a request body: bodyless requests
  (GET/HEAD/DELETE/LIST) sign the empty-payload SHA-256, so they are fully
  signed and deterministic; **PUT bodies use `UNSIGNED-PAYLOAD`**. Unsigned
  payload is a documented, valid S3 signing mode and lets `put` stream a Fetch
  `Body` without buffering it to compute a hash. Use HTTPS in production
  (R2/S3); MinIO over plain HTTP accepts it for local dev.
- **`put` requires a known `Content-Length`.** An unknown-length `Body` would be
  sent with `Transfer-Encoding: chunked`, which S3 and R2 reject (411/501) even
  though MinIO accepts it — a divergence invisible to the MinIO-only opt-in
  suite. `S3ObjectStore.put` asserts `body.contentLength != nil` and crashes
  early rather than emit a request only some backends honor. Stream from a
  length-known source (a file's size, a staged buffer's count).
- `x-amz-security-token` is added to the signed set when the credentials carry a
  session token.

## Transport, deadlines, and retries

`S3ObjectStore` takes a `FetchClient` rather than owning one, so the caller sets
the transport policy — and must set it deliberately. `FetchClient.asyncHTTPClient`'s
`timeout` is a **total request deadline**, not an idle timeout: its 30s default
will abort a large PUT mid-flight. Construct the adapter with a `nil` (or
generously large) timeout for a store that writes large objects, and a tight one
for a store that writes only small ones. The store performs **no retries**;
it surfaces `ObjectStoreError.unexpectedStatus` (and transport failures from the
`FetchClient`) unchanged. Retry/backoff policy — including which status codes are
retryable — is the caller's to own.

A 404 on `get`/`head` is mapped to `notFound(key)` / `nil` regardless of the S3
error code inside it: a genuinely missing key (`NoSuchKey`) and a misconfigured
or absent bucket (`NoSuchBucket`) are indistinguishable to callers here. Verify
the bucket/endpoint at configuration time; do not read a `notFound` as proof the
bucket exists.

## Addressing

`S3ObjectStore` supports both virtual-host (`<bucket>.<host>/<key>`, used by
Cloudflare R2) and path-style (`<host>/<bucket>/<key>`, used by MinIO and dev
setups) addressing. The `Host` header used for signing includes the port only
when it is non-default for the scheme, matching what AsyncHTTPClient sends.

## List

`ListObjectsV2` (`list-type=2`) with `prefix`, `continuation-token`, `max-keys`.
The XML `ListBucketResult` is parsed by a small, dependency-free byte scanner
(no `XMLParser`, no Foundation string search — keeps the backend
FoundationEssentials-friendly). Continuation tokens are opaque and passed back
verbatim. S3 returns keys in UTF-8 byte order; the filesystem backend sorts to
match, so pagination is stable across both backends.

`ObjectKey`'s invariants are enforced on every key parsed out of a listing. A key
written by a foreign client that violates them (a control character, a `..`
segment) makes `list` fail with `.malformedResponse` — one poisoned object
fails the whole page rather than silently skipping. This backend assumes it owns
its key space; if that stops holding, relax the parse to skip rather than reject.

## Filesystem backend

`FileSystemObjectStore` stores each object as a plain file at `root/<key>` —
jq-able, no sidecar metadata — so it does **not** round-trip content-type
(`ObjectStoreContract.Capabilities.preservesContentType == false`). Deletes are
idempotent and prune emptied parent directories.

## Compatibility note

Aliyun OSS exposes an S3-compatible endpoint that accepts SigV4 with virtual-host
or path-style addressing and `UNSIGNED-PAYLOAD`; it is a documented target for
this backend. No network calls are made in tests to verify it — the env-gated
MinIO suite (`KEEL_S3_ENDPOINT` …) is the only live path, opt-in and skipped in
CI.

## Not in scope

Content-addressed storage, key layout conventions, and retention/lifecycle
rules (bucket configuration, not code). The store takes keys as given.
