struct GenerateImageArguments: Decodable {
  var prompt: String
  var destination: String
  var provider: String?
  var model: String?
  var quality: String?
  var size: String?
}
