#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CanvasDocument
import LiveDocument
import struct SpaceContract.GroupID
import enum SpaceContract.LiveAccess
import enum SpaceContract.LiveErrorCode
import enum SpaceContract.LiveFrame
import struct SpaceContract.LivePeer
import enum SpaceContract.LiveServerControl
import SpaceFS
import WmdDocument
import Wuwei

/// What the transport hears from a document: a Loro frame or a JSON control.
public enum LiveOutbound: Sendable, Equatable {
  case control(LiveServerControl)
  case frame(LiveFrame)
}

/// What a client sends: its hello is taken by the route, so the cell sees binary frames only.
public enum LiveInbound: Sendable, Equatable {
  case binary([UInt8])
  case text(String)
  /// The transport heard that this connection's access to the group weakened: the cell refuses it.
  case weakened(LiveErrorCode)
}

/// One client's connection to a document. The connection id the protocol shows is the worker's socket id.
enum DocumentChannel: Socket {
  struct Opening: Sendable {
    var peer: String
    var name: String
    var access: LiveAccess
    var create: Bool
  }

  typealias Incoming = LiveInbound
  typealias Outgoing = LiveOutbound
}

/// What an agent's text is merged as: edits made at the latest checkpoint, at the one that wrote
/// `read`, or at the latest one, which must have written `current`.
enum DocumentBase: Sendable, Equatable {
  case latest
  case read(Int64)
  case current(Int64)
}

/// An agent's write of a document's whole text, as the fs hands it to the cell.
struct DocumentWrite: Sendable {
  var base: DocumentBase
  var createOnly: Bool
  var acting: GroupID
  var attribution: RevisionAttribution?
  /// The revision a checkout restores, journaled with the commit.
  var checkout: Int64?
}

enum DocumentWriteOutcome: Sendable, Equatable {
  case wrote(Int64)
  case stale
}

/// A step's refusal, answered to the socket or the caller rather than thrown past a close.
struct LiveRefusal: Error {
  let code: LiveErrorCode
  let message: String
}

/// The document's file is no longer the one its rows stand for.
struct DocumentGone: Error {}

/// A document kept live, by its file's extension.
enum LiveKind: String, CaseIterable, Sendable {
  case wmd
  case canvas

  var format: LiveFormat {
    switch self {
    case .wmd: .wmd
    case .canvas: .canvas
    }
  }
}

extension SpacePath {
  var liveKind: LiveKind? {
    guard let name = lastComponent, let dot = name.lastIndex(of: ".") else { return nil }
    return LiveKind(rawValue: String(name[name.index(after: dot)...]))
  }

  var isLive: Bool { liveKind != nil }
}

/// What a document cell cannot make itself: the process-wide replica cache, a peer id for each merge
/// of an agent's text, and the file's mtime.
struct Documents: Sendable {
  var replicas: DocumentReplicas
  var peer: @Sendable () -> UInt64
  var mtime: @Sendable () -> String
}

/// The peers a roster of sockets shows the protocol.
func roster(_ sockets: [SocketHandle<DocumentChannel>]) -> [LivePeer] {
  sockets.map {
    LivePeer(connection: String($0.id), peer: $0.opening.peer, name: $0.opening.name, access: $0.opening.access)
  }
}

/// Sends `refusal` to one socket and closes it; the others hear the new roster from its `closed`.
func refuse(_ socket: SocketHandle<DocumentChannel>, _ refusal: LiveRefusal) {
  socket.send(.control(.error(code: refusal.code, message: refusal.message)))
  socket.close()
}
