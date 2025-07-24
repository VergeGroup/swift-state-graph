import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct UnifiedStoredMacro {
  public enum Error: Swift.Error {
    case constantVariableIsNotSupported
    case computedVariableIsNotSupported
    case needsInitializer
    case didSetNotSupported
    case willSetNotSupported
    case userDefaultsRequiresDefaultValue
    case invalidBackingArgument
    case weakReferenceNotSupported
    case unownedReferenceNotSupported
  }
}


// MARK: - Diagnostic Messages

extension UnifiedStoredMacro.Error: DiagnosticMessage {
  public var message: String {
    switch self {
    case .constantVariableIsNotSupported:
      return "Constant variables are not supported with @GraphStored"
    case .computedVariableIsNotSupported:
      return "Computed variables are not supported with @GraphStored"
    case .needsInitializer:
      return "@GraphStored requires an initializer for non-optional properties"
    case .didSetNotSupported:
      return "didSet is not supported with @GraphStored"
    case .willSetNotSupported:
      return "willSet is not supported with @GraphStored"
    case .userDefaultsRequiresDefaultValue:
      return "@GraphStored with UserDefaults backing requires a default value"
    case .invalidBackingArgument:
      return "Invalid backing argument for @GraphStored"
    case .weakReferenceNotSupported:
      return "@GraphStored does not support weak references"
    case .unownedReferenceNotSupported:
      return "@GraphStored does not support unowned references"
    }
  }

  public var diagnosticID: MessageID {
    MessageID(domain: "UnifiedStoredMacro", id: "\(self)")
  }

  public var severity: DiagnosticSeverity {
    return .error
  }
}

// MARK: - Validation Helpers

extension UnifiedStoredMacro {

  /// Validates that the variable declaration is suitable for @GraphStored
  private static func validateDeclaration(
    _ variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext,
    node: some SyntaxProtocol
  ) -> Bool {
    // Check type annotation is required (but initializer is not)
    guard variableDecl.typeSyntax != nil else {
      context.addDiagnostics(from: Error.needsInitializer, node: node)
      return false
    }

    // Check for weak/unowned modifiers
    if variableDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.weak) }) {
      context.addDiagnostics(from: Error.weakReferenceNotSupported, node: node)
      return false
    }
    if variableDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.unowned) }) {
      context.addDiagnostics(from: Error.unownedReferenceNotSupported, node: node)
      return false
    }

    // Check didSet/willSet
    if variableDecl.didSetBlock != nil {
      context.addDiagnostics(from: Error.didSetNotSupported, node: node)
      return false
    }

    if variableDecl.willSetBlock != nil {
      context.addDiagnostics(from: Error.willSetNotSupported, node: node)
      return false
    }

    return true
  }

  /// Checks if the macro should be ignored
  private static func shouldIgnoreMacro(_ variableDecl: VariableDeclSyntax) -> Bool {
    return variableDecl.attributes.contains {
      switch $0 {
      case .attribute(let attribute):
        return attribute.attributeName.description == "Ignored"
      case .ifConfigDecl:
        return false
      }
    }
  }

  /// Checks if any binding has computed property accessors
  private static func hasComputedProperties(_ variableDecl: VariableDeclSyntax) -> Bool {
    return variableDecl.bindings.contains { binding in
      binding.accessorBlock != nil
    }
  }
}



// MARK: - Variable Declaration Generation

extension UnifiedStoredMacro {

  /// Creates the storage variable declaration
  private static func createStorageDeclaration(
    from variableDecl: VariableDeclSyntax,
    storageExpression: ExprSyntax,
    initialValue: ExprSyntax,
    context: some MacroExpansionContext
  ) -> VariableDeclSyntax {
    let _ = variableDecl.name

    var storageDecl = variableDecl
      .trimmed
      .makeConstant()
      .inheritAccessControl(with: variableDecl)

    // Add @GraphIgnored attribute
    storageDecl.attributes = [.init(.init(stringLiteral: "@GraphIgnored"))]
    
    // If it's a static property, ensure the storage is also static
    if variableDecl.isStatic {
      var modifiers = storageDecl.modifiers
      if !modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) {
        modifiers.append(.init(name: .keyword(.static)))
      }
      storageDecl = storageDecl.with(\.modifiers, modifiers)
    }

    // Rename with $ prefix and remove type annotation (let Swift infer)
    storageDecl = storageDecl
      .renamingIdentifier(with: "$")
    
    // Remove type annotation from bindings
    storageDecl = storageDecl.with(
      \.bindings,
      PatternBindingListSyntax(
        storageDecl.bindings.map { binding in
          binding.with(\.typeAnnotation, nil)
        }
      )
    )

    // Set initializer to use new syntax and remove accessors
    let initExpression: ExprSyntax = "_Stored(storage: \(storageExpression), value: \(initialValue))"
    storageDecl = storageDecl.with(
      \.bindings,
      PatternBindingListSyntax(
        storageDecl.bindings.map { binding in
          binding
            .with(\.initializer, InitializerClauseSyntax(value: initExpression))
            .with(\.accessorBlock, nil)
        }
      )
    )

    return storageDecl
  }
}

// MARK: - PeerMacro Implementation

extension UnifiedStoredMacro: PeerMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {

    guard let variableDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }

    // Check if macro should be ignored
    guard !shouldIgnoreMacro(variableDecl) else {
      return []
    }

    // Skip if has computed properties
    guard !hasComputedProperties(variableDecl) else {
      return []
    }

    // Validate declaration
    guard validateDeclaration(variableDecl, context: context, node: declaration) else {
      return []
    }

    // Get storage expression from backed argument, default to .memory
    let storageExpression: ExprSyntax
    if let arguments = node.arguments?.as(LabeledExprListSyntax.self),
       let backedArgument = arguments.first(where: { $0.label?.text == "backed" }) {
      // Transform shorthand syntax to full marker syntax
      let expr = backedArgument.expression
      if let memberAccess = expr.as(MemberAccessExprSyntax.self),
         memberAccess.base == nil {
        // Handle .memory -> MemoryMarker.memory
        if memberAccess.declName.baseName.text == "memory" {
          storageExpression = "MemoryMarker.memory" as ExprSyntax
        } else {
          // For any other member access, pass through as-is
          storageExpression = expr
        }
      } else if let functionCall = expr.as(FunctionCallExprSyntax.self),
                let memberAccess = functionCall.calledExpression.as(MemberAccessExprSyntax.self),
                memberAccess.base == nil,
                memberAccess.declName.baseName.text == "userDefaults" {
        // Handle .userDefaults(...) -> UserDefaultsMarker.userDefaults(...)
        let newCallee = ExprSyntax("UserDefaultsMarker.userDefaults")
        storageExpression = ExprSyntax(functionCall.with(\.calledExpression, newCallee))
      } else {
        // For fully qualified expressions, pass through as-is
        storageExpression = expr
      }
    } else {
      // No arguments provided, use memory storage as default
      storageExpression = "MemoryMarker.memory" as ExprSyntax
    }
    
    // Get initial value
    let initialValue: ExprSyntax
    if let binding = variableDecl.bindings.first,
       let initClause = binding.initializer {
      // Check if the initializer is nil and we have an optional type
      let initValue = initClause.value
      if initValue.description == "nil" && 
         (variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional) {
        // Use typed nil for proper type inference
        let typeSyntax = variableDecl.typeSyntax!
        // Handle implicitly unwrapped optional specially
        if variableDecl.isImplicitlyUnwrappedOptional {
          let baseType = typeSyntax.removingOptionality()
          initialValue = "nil as \(baseType.trimmed)?" as ExprSyntax
        } else {
          initialValue = "nil as \(typeSyntax.trimmed)" as ExprSyntax
        }
      } else {
        // For expressions like .init(), we need to preserve type context
        let initString = initValue.trimmed.description
        if initString == ".init()" {
          // Add explicit type for .init() expressions
          let typeSyntax = variableDecl.typeSyntax!
          initialValue = "\(typeSyntax.trimmed)()" as ExprSyntax
        } else {
          initialValue = initValue
        }
      }
    } else {
      // Handle properties without initializer
      if variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional {
        // Use typed nil for proper type inference
        let typeSyntax = variableDecl.typeSyntax!
        // Handle implicitly unwrapped optional specially
        if variableDecl.isImplicitlyUnwrappedOptional {
          let baseType = typeSyntax.removingOptionality()
          initialValue = "nil as \(baseType.trimmed)?" as ExprSyntax
        } else {
          initialValue = "nil as \(typeSyntax.trimmed)" as ExprSyntax
        }
      } else {
        // For non-optional properties without initializer, use appropriate default values
        // The property will be set in the initializer before it's accessed
        let typeSyntax = variableDecl.typeSyntax!
        let typeString = typeSyntax.trimmed.description
        
        // Provide appropriate default values based on common types
        switch typeString {
        case "String":
          initialValue = "\"\"" as ExprSyntax
        case "Int", "Int32", "Int64", "UInt", "UInt32", "UInt64":
          initialValue = "0" as ExprSyntax
        case "Double", "Float", "CGFloat":
          initialValue = "0.0" as ExprSyntax
        case "Bool":
          initialValue = "false" as ExprSyntax
        default:
          // For other types, try to use the default initializer
          // This is a fallback that may not always work
          if typeString.contains("<") || typeString.contains("[") {
            // For generic types or arrays, use empty initialization
            initialValue = "\(typeSyntax.trimmed)()" as ExprSyntax
          } else {
            // For custom types, try default init or use placeholder
            initialValue = "\(typeSyntax.trimmed)()" as ExprSyntax
          }
        }
      }
    }

    // Create storage declaration
    let storageDecl = createStorageDeclaration(
      from: variableDecl,
      storageExpression: storageExpression,
      initialValue: initialValue,
      context: context
    )

    return [DeclSyntax(storageDecl)]
  }
}

// MARK: - AccessorMacro Implementation

extension UnifiedStoredMacro: AccessorMacro {

  public static func expansion(
    of node: SwiftSyntax.AttributeSyntax,
    providingAccessorsOf declaration: some SwiftSyntax.DeclSyntaxProtocol,
    in context: some SwiftSyntaxMacros.MacroExpansionContext
  ) throws -> [SwiftSyntax.AccessorDeclSyntax] {

    guard let variableDecl = declaration.as(VariableDeclSyntax.self),
      let binding = variableDecl.bindings.first,
      let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self)
    else {
      return []
    }

    let propertyName = identifierPattern.identifier.text

    // Validate for accessor generation
    guard !variableDecl.isComputed else {
      context.addDiagnostics(from: Error.computedVariableIsNotSupported, node: declaration)
      return []
    }

    guard !variableDecl.isConstant else {
      context.addDiagnostics(from: Error.constantVariableIsNotSupported, node: declaration)
      return []
    }
    
    // All properties with type annotations can have accessors generated
    // Properties without initializers will be handled by using placeholder values

    // Simple accessors that just delegate to the storage
    return [
      AccessorDeclSyntax("get { return $\(raw: propertyName).wrappedValue }"),
      AccessorDeclSyntax("set { $\(raw: propertyName).wrappedValue = newValue }")
    ]
  }
}
