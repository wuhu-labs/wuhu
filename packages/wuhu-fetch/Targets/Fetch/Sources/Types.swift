#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import HTTPTypes

public typealias Bytes = Data
public typealias Headers = HTTPFields
public typealias Method = HTTPRequest.Method
public typealias Status = HTTPResponse.Status
