#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.ExecID
import struct MachineContract.MachineID
import enum MachineContract.SearchQuery
import enum MachineContract.VFSOp
import struct SessionDomain.SessionID
import struct SessionDomain.ToolCallID

struct MachineVFSRequest: Codable, Sendable { let session: SessionID; let machine: MachineID; let operation: VFSOp }
struct MachineSearchRequest: Codable, Sendable { let session: SessionID; let machine: MachineID; let query: SearchQuery }
struct ExecMintRequest: Codable, Sendable { let session: SessionID; let machine: MachineID; let script: String }
struct ExecClaimRequest: Codable, Sendable { let session: SessionID; let machine: MachineID; let call: ToolCallID }
struct ExecAccessRequest: Codable, Sendable { let session: SessionID; let id: ExecID }
struct FrameRequest: Codable, Sendable { let id: UUID; let frame: Data }
