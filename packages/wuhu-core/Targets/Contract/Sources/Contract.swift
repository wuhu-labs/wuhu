@attached(member, names: named(jsonSchema), named(init), named(encode(to:)))
public macro Contract(discriminator: String = "kind") = #externalMacro(module: "ContractMacros", type: "ContractMacro")
