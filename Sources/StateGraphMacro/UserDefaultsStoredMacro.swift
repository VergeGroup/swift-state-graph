import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct UserDefaultsStoredMacro {
  public enum Error: Swift.Error {
    case constantVariableIsNotSupported
    case computedVariableIsNotSupported
    case needsTypeAnnotation
    case needsDefaultValue
    case didSetNotSupported
    case willSetNotSupported
    case keyParameterRequired
    case invalidArgumentType
  }
}

extension UserDefaultsStoredMacro.Error: DiagnosticMessage {
  public var message: String {
    switch self {
    case .constantVariableIsNotSupported:
      return "Constant variables are not supported with @UserDefaultsStored"
    case .computedVariableIsNotSupported:
      return "Computed variables are not supported with @UserDefaultsStored"
    case .needsTypeAnnotation:
      return "@UserDefaultsStored requires explicit type annotation"
    case .needsDefaultValue:
      return "@UserDefaultsStored requires a default value"
    case .didSetNotSupported:
      return "didSet is not supported with @UserDefaultsStored"
    case .willSetNotSupported:
      return "willSet is not supported with @UserDefaultsStored"
    case .keyParameterRequired:
      return "@UserDefaultsStored requires a 'key' parameter"
    case .invalidArgumentType:
      return "Invalid argument type for @UserDefaultsStored"
    }
  }
  
  public var diagnosticID: MessageID {
    MessageID(domain: "UserDefaultsStoredMacro", id: "\(self)")
  }
  
  public var severity: DiagnosticSeverity {
    return .error
  }
}

extension UserDefaultsStoredMacro: PeerMacro {

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

    for binding in variableDecl.bindings {
      if binding.accessorBlock != nil {
        // skip computed properties
        continue
      }
    }

    // Parse macro arguments
    let arguments = node.arguments?.as(LabeledExprListSyntax.self)
    var keyArgument: String?
    var suiteArgument: String?
    var nameArgument: String?

    for argument in arguments ?? [] {
      if let label = argument.label?.text {
        switch label {
        case "key":
          if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
             let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            keyArgument = segment.content.text
          }
        case "suite":
          if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
             let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            suiteArgument = segment.content.text
          }
        case "name":
          if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
             let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            nameArgument = segment.content.text
          }
        default:
          break
        }
      }
    }

    guard let key = keyArgument else {
      context.addDiagnostics(from: Error.keyParameterRequired, node: node)
      return []
    }

    let prefix = "$"

    var _variableDecl = variableDecl
      .trimmed
      .makeConstant()
      .inheritAccessControl(with: variableDecl)

    _variableDecl.attributes = [.init(.init(stringLiteral: "@GraphIgnored"))]

    _variableDecl =
      _variableDecl
      .renamingIdentifier(with: prefix)
      .modifyingTypeAnnotation({ type in
        return "UserDefaultsStored<\(type.trimmed)>"
      })
    
    let propertyName = variableDecl.name
    let groupName = context.lexicalContext.first?.as(ClassDeclSyntax.self)?.name.text ?? ""
    let nodeName = nameArgument ?? propertyName

    if variableDecl.hasInitializer == false {
      context.addDiagnostics(from: Error.needsDefaultValue, node: declaration)
      return []
    }

    _variableDecl = _variableDecl.modifyingInit({ initializer in
      if let suite = suiteArgument {
        return .init(
          value: #".init(group: "\#(raw: groupName)", name: "\#(raw: nodeName)", suite: "\#(raw: suite)", key: "\#(raw: key)", defaultValue: \#(initializer.trimmed.value))"# as ExprSyntax
        )
      } else {
        return .init(
          value: #".init(group: "\#(raw: groupName)", name: "\#(raw: nodeName)", key: "\#(raw: key)", defaultValue: \#(initializer.trimmed.value))"# as ExprSyntax
        )
      }
    })

    // remove accessors
    _variableDecl = _variableDecl.with(
      \.bindings,
      .init(
        _variableDecl.bindings.map { binding in
          binding.with(\.accessorBlock, nil)
        }
      )
    )

    newMembers.append(DeclSyntax(_variableDecl))

    return newMembers
  }
}

extension UserDefaultsStoredMacro: AccessorMacro {

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

    let propertyName = identifierPattern.identifier.text

    guard variableDecl.isComputed == false else {
      context.addDiagnostics(from: Error.computedVariableIsNotSupported, node: declaration)
      return []
    }

    guard variableDecl.isConstant == false else {
      context.addDiagnostics(from: Error.constantVariableIsNotSupported, node: declaration)
      return []
    }
    
    let addsStorageRestrictions = !variableDecl.hasInitializer

    let initAccessor = AccessorDeclSyntax(
      """
      @storageRestrictions(
        initializes: $\(raw: propertyName)
      )
      init(initialValue) {
        // This should be handled by PeerMacro
        fatalError("UserDefaultsStored requires default value")
      }
      """
    )

    let readAccessor = AccessorDeclSyntax(
      """
      get {
        return $\(raw: propertyName).wrappedValue
      }
      """
    )

    let setAccessor = AccessorDeclSyntax(
      """
      set { 
        $\(raw: propertyName).wrappedValue = newValue
      }
      """
    )

    var accessors: [AccessorDeclSyntax] = []

    if addsStorageRestrictions {
      accessors.append(initAccessor)
    }

    accessors.append(readAccessor)
    accessors.append(setAccessor)

    return accessors
  }
} 