import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftDiagnostics

public struct UnifiedStoredMacro {
  public enum Error: Swift.Error {
    case constantVariableIsNotSupported
    case computedVariableIsNotSupported
    case needsTypeAnnotation
    case didSetNotSupported
    case willSetNotSupported
    case userDefaultsRequiresDefaultValue
    case invalidBackingArgument
  }
}

extension UnifiedStoredMacro.Error: DiagnosticMessage {
  public var message: String {
    switch self {
    case .constantVariableIsNotSupported:
      return "Constant variables are not supported with @GraphStored"
    case .computedVariableIsNotSupported:
      return "Computed variables are not supported with @GraphStored"
    case .needsTypeAnnotation:
      return "@GraphStored requires explicit type annotation"
    case .didSetNotSupported:
      return "didSet is not supported with @GraphStored"
    case .willSetNotSupported:
      return "willSet is not supported with @GraphStored"
    case .userDefaultsRequiresDefaultValue:
      return "@GraphStored with UserDefaults backing requires a default value"
    case .invalidBackingArgument:
      return "Invalid backing argument for @GraphStored"
    }
  }
  
  public var diagnosticID: MessageID {
    MessageID(domain: "UnifiedStoredMacro", id: "\(self)")
  }
  
  public var severity: DiagnosticSeverity {
    return .error
  }
}

enum BackingStorageType {
  case memory
  case userDefaults(key: String, suite: String?, name: String?)
}

extension UnifiedStoredMacro: PeerMacro {

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

    // Parse backing storage type
    let backingType = parseBackingStorageType(from: node, context: context)

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
        switch backingType {
        case .memory:
          if variableDecl.isWeak {
            return "Stored<Weak<\(type.removingOptionality().trimmed)>>"
          } else if variableDecl.isUnowned {
            return "Stored<Unowned<\(type.removingOptionality().trimmed)>>"
          } else if variableDecl.isImplicitlyUnwrappedOptional {
            return "Stored<\(type.removingOptionality().trimmed)?>"
          } else {
            return "Stored<\(type.trimmed)>"
          }
        case .userDefaults:
          return "UserDefaultsStored<\(type.trimmed)>"
        }
      })
    
    let propertyName = variableDecl.name
    let groupName = context.lexicalContext.first?.as(ClassDeclSyntax.self)?.name.text ?? ""

    // Handle initialization based on backing type
    switch backingType {
    case .memory:
      // Use existing logic from StoredMacro - same as the original StoredMacro implementation
      if (variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional) && variableDecl.hasInitializer == false {

        _variableDecl = _variableDecl.addInitializer({ 
          
          if variableDecl.isWeak {
            return .init(
              value: #".init(group: "\#(raw: groupName)", name: "\#(raw: propertyName)", wrappedValue: .init(nil))"# as ExprSyntax)
          } else if variableDecl.isUnowned {
            return .init(
              value: #".init(group: "\#(raw: groupName)", name: "\#(raw: propertyName)", wrappedValue: .init(nil))"# as ExprSyntax)
          } else {
            return .init(value: #".init(group: "\#(raw: groupName)", name: "\#(raw: propertyName)", wrappedValue: nil)"# as ExprSyntax)
          }
          
        }())
      } else {
        // Only modify init if there's an initializer (this handles both optional and non-optional cases with initializers)
        _variableDecl = _variableDecl.modifyingInit({ initializer in

          if variableDecl.isWeak {
            return .init(
              value: #".init(group: "\#(raw: groupName)", name: "\#(raw: propertyName)", wrappedValue: .init(\#(initializer.trimmed.value)))"# as ExprSyntax)
          } else if variableDecl.isUnowned {
            return .init(
              value: #".init(group: "\#(raw: groupName)", name: "\#(raw: propertyName)", wrappedValue: .init(\#(initializer.trimmed.value)))"# as ExprSyntax)
          } else {
            return .init(value: #".init(group: "\#(raw: groupName)", name: "\#(raw: propertyName)", wrappedValue: \#(initializer.trimmed.value))"# as ExprSyntax)
          }

        })
      }

    case .userDefaults(let key, let suite, let nodeName):
      // Use logic from UserDefaultsStoredMacro
      if variableDecl.hasInitializer == false {
        context.addDiagnostics(from: Error.userDefaultsRequiresDefaultValue, node: declaration)
        return []
      }

      let finalNodeName = nodeName ?? propertyName

      _variableDecl = _variableDecl.modifyingInit({ initializer in
        if let suite = suite {
          return .init(
            value: #".init(group: "\#(raw: groupName)", name: "\#(raw: finalNodeName)", suite: "\#(raw: suite)", key: "\#(raw: key)", defaultValue: \#(initializer.trimmed.value))"# as ExprSyntax
          )
        } else {
          return .init(
            value: #".init(group: "\#(raw: groupName)", name: "\#(raw: finalNodeName)", key: "\#(raw: key)", defaultValue: \#(initializer.trimmed.value))"# as ExprSyntax
          )
        }
      })
    }

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

  private static func parseBackingStorageType(from node: AttributeSyntax, context: some MacroExpansionContext) -> BackingStorageType {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
      return .memory // Default to memory if no arguments
    }

    for argument in arguments {
      if argument.label?.text == "backed" {
        // Handle function call like .userDefaults(key: "key")
        if let functionCall = argument.expression.as(FunctionCallExprSyntax.self) {
          if let callee = functionCall.calledExpression.as(MemberAccessExprSyntax.self),
             callee.declName.baseName.text == "userDefaults" {
            return parseUserDefaultsArguments(from: functionCall.arguments)
          }
        }
        // Handle member access like .memory
        else if let memberAccess = argument.expression.as(MemberAccessExprSyntax.self) {
          if memberAccess.declName.baseName.text == "memory" {
            return .memory
          }
        }
      }
    }

    return .memory // Default fallback
  }

  private static func parseUserDefaultsArguments(from arguments: LabeledExprListSyntax) -> BackingStorageType {
    var key: String?
    var suite: String?
    var name: String?

    for argument in arguments {
      if let label = argument.label?.text {
        switch label {
        case "key":
          if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
             let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            key = segment.content.text
          }
        case "suite":
          if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
             let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            suite = segment.content.text
          }
        case "name":
          if let stringLiteral = argument.expression.as(StringLiteralExprSyntax.self),
             let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self) {
            name = segment.content.text
          }
        default:
          break
        }
      }
    }

    if let key = key {
      return .userDefaults(key: key, suite: suite, name: name)
    } else {
      return .memory // Fallback if key is missing
    }
  }
}

extension UnifiedStoredMacro: AccessorMacro {

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

    // Parse backing storage type
    let backingType = parseBackingStorageType(from: node, context: context)
    
    switch backingType {
    case .memory:
      return generateMemoryAccessors(for: propertyName, variableDecl: variableDecl)
    case .userDefaults:
      return generateUserDefaultsAccessors(for: propertyName, variableDecl: variableDecl)
    }
  }

  private static func generateMemoryAccessors(for propertyName: String, variableDecl: VariableDeclSyntax) -> [AccessorDeclSyntax] {
    let addsStorageRestrictions = { () -> Bool in
      if variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional {
        return false
      } else {
        if variableDecl.hasInitializer {
          return false
        } else {
          return true
        }
      }
    }()
    
    if variableDecl.isWeak || variableDecl.isUnowned {
      let initAccessor = AccessorDeclSyntax(
        """
        @storageRestrictions(
          initializes: $\(raw: propertyName)
        )
        init(initialValue) {
          $\(raw: propertyName) = .init(wrappedValue: .init(initialValue))
        }
        """
      )

      let readAccessor = AccessorDeclSyntax(
        """
        get {
          return $\(raw: propertyName).wrappedValue.value\(raw: variableDecl.isImplicitlyUnwrappedOptional ? "!" : "")
        }
        """
      )

      let setAccessor = AccessorDeclSyntax(
        """
        set { 
          $\(raw: propertyName).wrappedValue.value = newValue
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
    } else {
      let initAccessor = AccessorDeclSyntax(
        """
        @storageRestrictions(
          initializes: $\(raw: propertyName)
        )
        init(initialValue) {
          $\(raw: propertyName) = .init(wrappedValue: initialValue)
        }
        """
      )

      let readAccessor = AccessorDeclSyntax(
        """
        get {
          return $\(raw: propertyName).wrappedValue\(raw: variableDecl.isImplicitlyUnwrappedOptional ? "!" : "")
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

  private static func generateUserDefaultsAccessors(for propertyName: String, variableDecl: VariableDeclSyntax) -> [AccessorDeclSyntax] {
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