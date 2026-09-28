import JSONValue
import struct SpaceContract.DevicePayload
import struct SpaceContract.DevicesOutput

extension Executor {
  mutating func deviceList() async throws {
    let space = try self.wallet.pinnedSpace()
    let output: DevicesOutput = try await self.api(.get, "/v1/devices", space: space)
    let text = output.devices.map { device in
      "\(device.id) \(device.kind) \(device.machine ?? "-") \(device.name)\n"
    }.joined()
    await self.runner.stdout(text)
  }

  mutating func deviceSet(id: String, name: String?, machine: String?) async throws {
    let space = try self.wallet.pinnedSpace()
    var body: JSONValue = .object([:])
    body.set("name", name.map(JSONValue.string))
    body.set("machine", machine.map(JSONValue.string))
    let device: DevicePayload = try await self.api(.patch, "/v1/device/\(id)", space: space, body: body)
    await self.runner.stdout("\(device.id) \(device.kind) \(device.machine ?? "-") \(device.name)\n")
  }
}
