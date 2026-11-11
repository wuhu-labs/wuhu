/// `fallback` names a receive-only case (`case x`, or `case x(<discriminator>: String)` in a union) that an unknown wire value decodes to; it is left out of the schema and encoding it throws.
@attached(member, names: named(jsonSchema), named(init), named(encode(to:)))
public macro Contract(discriminator: String = "kind", fallback: String? = nil) = #externalMacro(module: "ContractMacros", type: "ContractMacro")
