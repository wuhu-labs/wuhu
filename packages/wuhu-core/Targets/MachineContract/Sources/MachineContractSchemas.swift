import JSONValue

public enum MachineContractSchemas {
  public static let all: [(name: String, schema: JSONValue)] = [
    ("MachineID", MachineID.jsonSchema),
    ("ExecID", ExecID.jsonSchema),
    ("Base64Data", Base64Data.jsonSchema),
    ("StringMap", StringMap.jsonSchema),

    ("MachineErrorCode", MachineErrorCode.jsonSchema),
    ("MachineError", MachineError.jsonSchema),

    ("MachineAddInput", MachineAddInput.jsonSchema),
    ("MachineAddOutput", MachineAddOutput.jsonSchema),
    ("MachineChallengeOutput", MachineChallengeOutput.jsonSchema),
    ("MachineNameInput", MachineNameInput.jsonSchema),
    ("MachineMoveInput", MachineMoveInput.jsonSchema),
    ("MachineRotateInput", MachineRotateInput.jsonSchema),
    ("MachineRotateOutput", MachineRotateOutput.jsonSchema),
    ("MachineRevokeInput", MachineRevokeInput.jsonSchema),
    ("MachineStatus", MachineStatus.jsonSchema),
    ("ExecMintInput", ExecMintInput.jsonSchema),
    ("ExecMintOutput", ExecMintOutput.jsonSchema),
    ("ExecState", ExecState.jsonSchema),
    ("ExecStatus", ExecStatus.jsonSchema),

    ("Opcode", Opcode.jsonSchema),
    ("Frame", Frame.jsonSchema),
    ("ControlMessage", ControlMessage.jsonSchema),

    ("ExecSessionCredential", ExecSessionCredential.jsonSchema),
    ("ExecStart", ExecStart.jsonSchema),
    ("StdinChunk", StdinChunk.jsonSchema),
    ("StdinEOF", StdinEOF.jsonSchema),
    ("ExecOutputStream", ExecOutputStream.jsonSchema),
    ("OutputChunk", OutputChunk.jsonSchema),
    ("ExitStatus", ExitStatus.jsonSchema),
    ("ExecExit", ExecExit.jsonSchema),
    ("Ack", Ack.jsonSchema),
    ("Kill", Kill.jsonSchema),
    ("ExecEvent", ExecEvent.jsonSchema),

    ("MachineEntryKind", MachineEntryKind.jsonSchema),
    ("MachineEntry", MachineEntry.jsonSchema),
    ("VFSOp", VFSOp.jsonSchema),
    ("VFSRequest", VFSRequest.jsonSchema),
    ("VFSResult", VFSResult.jsonSchema),
    ("VFSResponse", VFSResponse.jsonSchema),

    ("SearchMatch", SearchMatch.jsonSchema),
    ("SearchQuery", SearchQuery.jsonSchema),
    ("SearchRequest", SearchRequest.jsonSchema),
    ("SearchResult", SearchResult.jsonSchema),
    ("SearchResponse", SearchResponse.jsonSchema),
  ]
}
