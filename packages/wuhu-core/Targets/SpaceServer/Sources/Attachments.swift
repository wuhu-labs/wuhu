#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import Serve
import enum SpaceContract.AttachmentLimits
import enum SpaceContract.AttachmentRefusal
import struct SpaceContract.AttachmentTally
import struct SpaceContract.ConversationPostInput
import struct SpaceContract.GroupID
import SpaceCore

enum PostVerdict {
  case post(ConversationPostInput, [AttachmentUpload])
  case refused(Response)
}

let maximumPostFieldsBytes = 8 << 20

// Room for the message part and every part's headers on top of the files; a
// body past it is cut off by the transport before the route sees it.
let maximumPostBodyBytes = AttachmentLimits.maxTotalBytes + (16 << 20)

func readPost(_ request: Request, space: Space, principal: Principal) async -> PostVerdict {
  let contentType = request.headers[.contentType] ?? request.body?.contentType ?? ""
  var tally = AttachmentTally()
  var uploads: [AttachmentUpload] = []
  let input: ConversationPostInput
  if MultipartReader.boundary(of: contentType) != nil {
    switch await readMultipart(request.body ?? .empty, contentType: contentType, tally: &tally) {
    case let .success((posted, files)):
      input = posted
      uploads = files
    case let .failure(refusal):
      return .refused(refusal.response)
    }
  } else {
    do {
      input = try await request.json(ConversationPostInput.self, upTo: maximumPostFieldsBytes)
    } catch FetchError.bodyLimitExceeded {
      return .refused(errorResponse(
        .contentTooLarge,
        code: "invalidArgument",
        message: "a conversation post is at most \(maximumPostFieldsBytes) bytes",
      ))
    } catch {
      return .refused(errorResponse(.badRequest, code: "invalidArgument", message: "expected a conversation-post body: \(error)"))
    }
  }
  for path in input.attachments ?? [] {
    switch await spaceFile(path, as: principal, space: space, tally: &tally) {
    case let .success(upload): uploads.append(upload)
    case let .failure(refusal): return .refused(refusal.response)
    }
  }
  return .post(input, uploads)
}

private struct Refusal: Error {
  let response: Response

  init(_ response: Response) {
    self.response = response
  }

  init(_ refusal: AttachmentRefusal) {
    let status: Status = if case .tooMany = refusal { .badRequest } else { .contentTooLarge }
    response = errorResponse(status, code: refusal.code, message: refusal.message)
  }
}

// Each file is held only until its part ends and a limit is checked at every
// chunk, so a refused upload stops at the byte that broke the limit.
private func readMultipart(
  _ body: Body,
  contentType: String,
  tally: inout AttachmentTally,
) async -> Result<(ConversationPostInput, [AttachmentUpload]), Refusal> {
  var reader: MultipartReader
  do {
    reader = try MultipartReader(body: body, contentType: contentType)
  } catch {
    return .failure(Refusal(errorResponse(.badRequest, code: "invalidArgument", message: "expected a multipart/form-data boundary")))
  }
  var fields: Data?
  var uploads: [AttachmentUpload] = []
  do {
    while let part = try await reader.nextPart() {
      switch part.name {
      case "message":
        guard fields == nil else {
          return .failure(Refusal(errorResponse(.badRequest, code: "invalidArgument", message: "a conversation post has one part named message")))
        }
        var bytes = Data()
        while let chunk = try await reader.nextChunk() {
          bytes.append(chunk)
          guard bytes.count <= maximumPostFieldsBytes else {
            return .failure(Refusal(errorResponse(
              .contentTooLarge,
              code: "invalidArgument",
              message: "the message part of a conversation post is at most \(maximumPostFieldsBytes) bytes",
            )))
          }
        }
        fields = bytes
      case "file":
        let name = part.filename ?? "attachment"
        try tally.open(name)
        var bytes: [UInt8] = []
        while let chunk = try await reader.nextChunk() {
          try tally.add(chunk.count, to: name)
          bytes.append(contentsOf: chunk)
        }
        uploads.append(AttachmentUpload(name: name, bytes: bytes, declaredType: part.contentType))
      default:
        return .failure(Refusal(errorResponse(
          .badRequest,
          code: "invalidArgument",
          message: "a conversation post has parts named message and file, not \(part.name ?? "an unnamed part")",
        )))
      }
    }
  } catch let refusal as AttachmentRefusal {
    await drain(&reader)
    return .failure(Refusal(refusal))
  } catch ServeError.requestBodyTooLarge {
    return .failure(Refusal(.totalTooLarge(name: "the request body")))
  } catch {
    return .failure(Refusal(errorResponse(.badRequest, code: "invalidArgument", message: "unreadable multipart body: \(error)")))
  }
  guard let fields else {
    return .failure(Refusal(errorResponse(.badRequest, code: "invalidArgument", message: "a conversation post needs a part named message")))
  }
  do {
    return .success((try await Body.bytes(fields).json(ConversationPostInput.self), uploads))
  } catch {
    return .failure(Refusal(errorResponse(.badRequest, code: "invalidArgument", message: "expected a conversation-post message part: \(error)")))
  }
}

// The client is still sending when a limit refuses it; reading the rest lets
// it see the refusal instead of a reset connection. The transport's own body
// bound caps what this reads.
private func drain(_ reader: inout MultipartReader) async {
  while (try? await reader.nextPart()) != nil {}
}

// A path is hostless in the acting group or names a group it reads by
// `wuhu://<group>.localspace/`, exactly as send_message takes it.
private func spaceFile(
  _ reference: String, as principal: Principal, space: Space, tally: inout AttachmentTally,
) async -> Result<AttachmentUpload, Refusal> {
  let missing = Refusal(errorResponse(.notFound, code: "notFound", message: "attachment \(reference) is not a file in the space"))
  let invalid = Refusal(errorResponse(
    .badRequest,
    code: "invalidArgument",
    message: "attachment \(reference) must be a space path: /<path>, or wuhu://<group>.localspace/<path> for another group",
  ))
  let named: (group: GroupID, path: String)?
  do {
    named = try GroupID.address(reference)
  } catch {
    return .failure(invalid)
  }
  let group: GroupID
  let path: String
  if let qualified = named {
    group = qualified.group
    path = qualified.path
    guard await readable(path, in: group, by: principal, space: space) else { return .failure(missing) }
  } else {
    group = principal.group
    path = reference
  }
  guard path.hasPrefix("/") else { return .failure(invalid) }
  let fs = await space.fs(group)
  guard let entry = try? await fs.stat(path), entry.kind == .file else { return .failure(missing) }
  do {
    try tally.admit(reference, size: entry.size)
  } catch {
    return .failure(Refusal(error))
  }
  guard let (_, data) = try? await fs.read(path) else { return .failure(missing) }
  return .success(AttachmentUpload(name: path, bytes: [UInt8](data)))
}

private func readable(_ path: String, in group: GroupID, by principal: Principal, space: Space) async -> Bool {
  if group == principal.group { return true }
  if (try? await space.reads(principal.group).contains(group)) == true { return true }
  guard let member = principal.member else { return false }
  return (try? await space.sessions.readsAttachment(path, in: group, member: member)) == true
}
