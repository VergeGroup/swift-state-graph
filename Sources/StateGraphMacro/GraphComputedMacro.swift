import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Turns a computed property body into a lazily cached graph node and a forwarding getter.
public struct GraphComputedMacro: PeerMacro, BodyMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let variable = declaration.as(VariableDeclSyntax.self),
          variable.bindings.count == 1,
          let type = variable.typeSyntax?.trimmed,
          let body = variable.getBlock,
          !variable.isConstant,
          !variable.hasInitializer
    else {
      throw Error.requiresComputedProperty
    }

    if case .accessors(let accessors) = variable.bindings.first?.accessorBlock?.accessors {
      guard accessors.count == 1,
            let getter = accessors.first,
            getter.accessorSpecifier.tokenKind == .keyword(.get),
            getter.effectSpecifiers == nil
      else {
        throw Error.requiresSynchronousGetter
      }
    }

    let name = variable.name
    let projection = try VariableDeclSyntax("var $\(raw: name): Computed<\(type)>")
      .inheritAccessControl(with: variable)
      .trimmed

    if !variable.isStatic,
       let enclosingType = context.lexicalContext.first(where: { $0.isProtocol(DeclGroupSyntax.self) })
    {
      guard let owner = enclosingType.as(ClassDeclSyntax.self) else {
        throw Error.requiresClassOwner
      }
      let ownerType = owner.name.trimmed
      return [
        """
        @GraphIgnored
        private let _\(raw: name): GraphComputedBacking<\(ownerType), \(type)> = .init(name: "\(raw: name)", ownerType: \(ownerType).self) { owner, context in
          owner._compute_\(raw: name)(&context)
        }
        """,
        """
        @GraphIgnored
        \(projection) {
          _\(raw: name).node(owner: self)
        }
        """,
        """
        @GraphIgnored
        private func _compute_\(raw: name)(_ context: inout Computed<\(type)>.Context) -> \(type) {
        \(body.trimmed)
        }
        """,
      ]
    }

    let staticModifier = if variable.isStatic { "static " } else { "" }
    return [
      """
      @GraphIgnored
      private \(raw: staticModifier)let _\(raw: name): GraphComputedGlobalBacking<\(type)> = .init(name: "\(raw: name)") { context in
        _compute_\(raw: name)(&context)
      }
      """,
      """
      @GraphIgnored
      \(raw: staticModifier)\(projection) {
        _\(raw: name).node()
      }
      """,
      """
      @GraphIgnored
      private \(raw: staticModifier)func _compute_\(raw: name)(_ context: inout Computed<\(type)>.Context) -> \(type) {
      \(body.trimmed)
      }
      """,
    ]
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
    in context: some MacroExpansionContext
  ) throws -> [CodeBlockItemSyntax] {
    guard declaration.is(AccessorDeclSyntax.self),
          let variable = context.lexicalContext.compactMap({ $0.as(VariableDeclSyntax.self) }).first
    else {
      return []
    }

    return ["return $\(raw: variable.name).wrappedValue"]
  }

  /// Describes declarations that cannot be represented by a cached, synchronous getter.
  private enum Error: Swift.Error, DiagnosticMessage {
    case requiresComputedProperty
    case requiresSynchronousGetter
    case requiresClassOwner

    var message: String {
      switch self {
      case .requiresComputedProperty:
        return "@GraphComputed requires a computed var with an explicit type; use @GraphComputedNode for a manually initialized node"
      case .requiresSynchronousGetter:
        return "@GraphComputed requires a synchronous, read-only getter"
      case .requiresClassOwner:
        return "@GraphComputed instance properties require a class owner; use @GraphComputedNode to store a node in a value type"
      }
    }

    var diagnosticID: MessageID { MessageID(domain: "GraphComputedMacro", id: "\(self)") }
    var severity: DiagnosticSeverity { .error }
  }
}
