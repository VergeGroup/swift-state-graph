
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ComputedMacro {

  public enum Error: Swift.Error {
    case constantVariableIsNotSupported
    case computedVariableIsNotSupported
    case needsTypeAnnotation
    case cannotHaveInitializer
    case didSetNotSupported
    case willSetNotSupported
    case weakVariableNotSupported
    case unownedVariableNotSupported
    case enclosingTypeNotFound
  }
}

extension ComputedMacro: PeerMacro {
  
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    
    guard let variableDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }
    
    guard variableDecl.typeSyntax != nil else {
      context.addDiagnostics(from: Error.needsTypeAnnotation, node: declaration)
      return []
    }
    
    // check the current limitation
    do {
      if variableDecl.didSetBlock != nil {
        context.addDiagnostics(from: Error.didSetNotSupported, node: declaration)
        return []
      }
      
      if variableDecl.willSetBlock != nil {
        context.addDiagnostics(from: Error.willSetNotSupported, node: declaration)
        return []
      }
    }
    
    var newMembers: [DeclSyntax] = []
    
    let ignoreMacroAttached = variableDecl.attributes.contains {
      switch $0 {
      case .attribute(let attribute):
        return attribute.attributeName.description == "Ignored"
      case .ifConfigDecl:
        return false
      }
    }
    
    guard !ignoreMacroAttached else {
      return []
    }
    
    let prefix = "$"
    let name = variableDecl.name
    let type = variableDecl.typeSyntax!.trimmed

    if let body = variableDecl.getBlock {
      if let ownerType = context.enclosingType, variableDecl.isStatic == false {
        return [
          """
          @GraphIgnored
          private let _graphComputedBacking_\(raw: name): GraphComputedBacking<\(ownerType), \(type)> = .init(name: "\(raw: name)", ownerType: \(ownerType).self) { owner, context in
            owner.__graphCompute_\(raw: name)(&context)
          }
          """,
          """
          @GraphIgnored
          var $\(raw: name): Computed<\(type)> {
            _graphComputedBacking_\(raw: name).node(owner: self)
          }
          """,
          """
          @GraphIgnored
          private func __graphCompute_\(raw: name)(_ context: inout Computed<\(type)>.Context) -> \(type) {
          \(body.trimmed)
          }
          """,
        ]
      } else {
        let staticModifier = variableDecl.isStatic ? "static " : ""
        return [
          """
          @GraphIgnored
          private \(raw: staticModifier)let _graphComputedBacking_\(raw: name): GraphComputedGlobalBacking<\(type)> = .init(name: "\(raw: name)") { context in
            __graphCompute_\(raw: name)(&context)
          }
          """,
          """
          @GraphIgnored
          \(raw: staticModifier)var $\(raw: name): Computed<\(type)> {
            _graphComputedBacking_\(raw: name).node()
          }
          """,
          """
          @GraphIgnored
          private \(raw: staticModifier)func __graphCompute_\(raw: name)(_ context: inout Computed<\(type)>.Context) -> \(type) {
          \(body.trimmed)
          }
          """,
        ]
      }
    }
    
    var _variableDecl = variableDecl
      .trimmed
      .makeConstant()
      .inheritAccessControl(with: variableDecl)
    
    _variableDecl.attributes = [.init(.init(stringLiteral: "@GraphIgnored"))]
    
    _variableDecl =
    _variableDecl
      .renamingIdentifier(with: prefix)
      .modifyingTypeAnnotation({ type in
        return "Computed<\(type.trimmed)>"
      })
    
    if variableDecl.isOptional && variableDecl.hasInitializer == false {
      
    } else {
      _variableDecl = _variableDecl.modifyingInit({ initializer in
        
        if variableDecl.isWeak {
          return .init(
            value: #".init(name: "\#(raw: name)", wrappedValue: .init(\#(initializer.trimmed.value)))"# as ExprSyntax)
        } else if variableDecl.isUnowned {
          return .init(
            value: #".init(name: "\#(raw: name)", wrappedValue: .init(\#(initializer.trimmed.value)))"# as ExprSyntax)
        } else {
          return .init(value: #".init(name: "\#(raw: name)", wrappedValue: \#(initializer.trimmed.value))"# as ExprSyntax)
        }
        
      })
    }
    
    do {
      
      // remove accessors
      _variableDecl = _variableDecl.with(
        \.bindings,
         .init(
          _variableDecl.bindings.map { binding in
            binding.with(\.accessorBlock, nil)
          }
         )
      )
      
    }
    
    newMembers.append(DeclSyntax(_variableDecl))
    
    return newMembers
  }
}

extension ComputedMacro: AccessorMacro {
  
  public static func expansion(
    of node: SwiftSyntax.AttributeSyntax,
    providingAccessorsOf declaration: some SwiftSyntax.DeclSyntaxProtocol,
    in context: some SwiftSyntaxMacros.MacroExpansionContext
  ) throws -> [SwiftSyntax.AccessorDeclSyntax] {
    
    guard let variableDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }
    
    guard let binding = variableDecl.bindings.first,
          let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self)
    else {
      return []
    }
        
    guard binding.initializer == nil else {
      context.addDiagnostics(from: Error.cannotHaveInitializer, node: declaration)
      return []      
    }
    
    let propertyName = identifierPattern.identifier.text
    
    if variableDecl.isComputed {
      return []
    }
    
    guard variableDecl.isConstant == false else {
      context.addDiagnostics(from: Error.constantVariableIsNotSupported, node: declaration)
      return []
    }
    
    guard variableDecl.isConstant == false else {
      fatalError()
    }
    
    guard !variableDecl.isWeak else {
      context.addDiagnostics(from: Error.weakVariableNotSupported, node: declaration)
      return []
    }

    guard !variableDecl.isUnowned else {
      context.addDiagnostics(from: Error.unownedVariableNotSupported, node: declaration)
      return []
    }
    
    let readAccessor = AccessorDeclSyntax(
      """
      get {
        return $\(raw: propertyName).wrappedValue
      }
      """
    )
    
    var accessors: [AccessorDeclSyntax] = []
          
    accessors.append(readAccessor)
    
    return accessors
  }
  
}

extension ComputedMacro: BodyMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
    in context: some MacroExpansionContext
  ) throws -> [CodeBlockItemSyntax] {
    guard declaration.is(AccessorDeclSyntax.self),
          let variableDecl = context.lexicalContext.compactMap({ $0.as(VariableDeclSyntax.self) }).last
    else {
      return []
    }

    let propertyName = variableDecl.name
    return [
      """
      return $\(raw: propertyName).wrappedValue
      """
    ]
  }
}

// MARK: - Diagnostic Messages

extension ComputedMacro.Error: DiagnosticMessage {
  public var message: String {
    switch self {
    case .constantVariableIsNotSupported:
      return "Constant variables are not supported with @GraphComputed"
    case .computedVariableIsNotSupported:
      return "Computed variables are not supported with @GraphComputed"
    case .needsTypeAnnotation:
      return "@GraphComputed requires explicit type annotation"
    case .cannotHaveInitializer:
      return "@GraphComputed cannot have an initializer"
    case .didSetNotSupported:
      return "didSet is not supported with @GraphComputed"
    case .willSetNotSupported:
      return "willSet is not supported with @GraphComputed"
    case .weakVariableNotSupported:
      return "weak variables are not supported with @GraphComputed"
    case .unownedVariableNotSupported:
      return "unowned variables are not supported with @GraphComputed"
    case .enclosingTypeNotFound:
      return "@GraphComputed with a computed body must be declared in a nominal type"
    }
  }

  public var diagnosticID: MessageID {
    MessageID(domain: "ComputedMacro", id: "\(self)")
  }

  public var severity: DiagnosticSeverity {
    return .error
  }
}

private extension MacroExpansionContext {
  var enclosingType: TypeSyntax? {
    for syntax in lexicalContext.reversed() {
      if let classDecl = syntax.as(ClassDeclSyntax.self) {
        return TypeSyntax(stringLiteral: classDecl.name.text)
      }
      if let structDecl = syntax.as(StructDeclSyntax.self) {
        return TypeSyntax(stringLiteral: structDecl.name.text)
      }
      if let actorDecl = syntax.as(ActorDeclSyntax.self) {
        return TypeSyntax(stringLiteral: actorDecl.name.text)
      }
    }
    return nil
  }
}
