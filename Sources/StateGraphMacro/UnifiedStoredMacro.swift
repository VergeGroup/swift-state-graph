import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

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

// MARK: - Configuration

extension UnifiedStoredMacro {
  /// Configuration for backing storage type
  enum BackingStorageType {
    case memory
    case userDefaults(Configuration)

    struct Configuration {
      let key: String
      let suite: String?
      let name: String?

      init(key: String, suite: String? = nil, name: String? = nil) {
        self.key = key
        self.suite = suite
        self.name = name
      }
    }
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

// MARK: - Validation Helpers

extension UnifiedStoredMacro {

  /// Validates that the variable declaration is suitable for @GraphStored
  private static func validateDeclaration(
    _ variableDecl: VariableDeclSyntax,
    backingType: BackingStorageType,
    context: some MacroExpansionContext,
    node: some SyntaxProtocol
  ) -> Bool {
    // Check type annotation
    guard variableDecl.typeSyntax != nil else {
      context.addDiagnostics(from: Error.needsTypeAnnotation, node: node)
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

    // UserDefaults specific validation
    if case .userDefaults = backingType {
      if !variableDecl.hasInitializer {
        context.addDiagnostics(from: Error.userDefaultsRequiresDefaultValue, node: node)
        return false
      }
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

// MARK: - Argument Parsing

extension UnifiedStoredMacro {

  /// Parses backing storage type from macro arguments
  private static func parseBackingStorageType(
    from node: AttributeSyntax,
    context: some MacroExpansionContext
  ) -> BackingStorageType {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
      return .memory  // Default to memory if no arguments
    }

    for argument in arguments {
      if argument.label?.text == "backed" {
        // Handle function call like .userDefaults(key: "key")
        if let functionCall = argument.expression.as(FunctionCallExprSyntax.self) {
          if let callee = functionCall.calledExpression.as(MemberAccessExprSyntax.self),
            callee.declName.baseName.text == "userDefaults"
          {
            let config = parseUserDefaultsArguments(from: functionCall.arguments)
            return .userDefaults(config)
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

    return .memory  // Default fallback
  }

  /// Parses UserDefaults arguments into Configuration
  private static func parseUserDefaultsArguments(
    from arguments: LabeledExprListSyntax
  ) -> BackingStorageType.Configuration {
    var key: String?
    var suite: String?
    var name: String?

    for argument in arguments {
      guard let label = argument.label?.text else { continue }

      let stringValue = extractStringLiteral(from: argument.expression)

      switch label {
      case "key":
        key = stringValue
      case "suite":
        suite = stringValue
      case "name":
        name = stringValue
      default:
        break
      }
    }

    // Use key or empty string as fallback (validation will catch missing key)
    return BackingStorageType.Configuration(
      key: key ?? "",
      suite: suite,
      name: name
    )
  }

  /// Extracts string literal value from expression
  private static func extractStringLiteral(from expression: ExprSyntax) -> String? {
    guard let stringLiteral = expression.as(StringLiteralExprSyntax.self),
      let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
    else {
      return nil
    }
    return segment.content.text
  }
}

// MARK: - Variable Declaration Generation

extension UnifiedStoredMacro {

  /// Creates the storage variable declaration
  private static func createStorageDeclaration(
    from variableDecl: VariableDeclSyntax,
    backingType: BackingStorageType,
    context: some MacroExpansionContext
  ) -> VariableDeclSyntax {
    let propertyName = variableDecl.name

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

    // Rename with $ prefix and update type
    storageDecl =
      storageDecl
      .renamingIdentifier(with: "$")
      .modifyingTypeAnnotation { type in
        return createTypeAnnotation(for: type, backingType: backingType, variableDecl: variableDecl)
      }

    // Handle initialization based on backing type
    storageDecl = createInitializer(
      for: storageDecl,
      variableDecl: variableDecl,
      backingType: backingType,
      propertyName: propertyName
    )

    // Remove accessors
    storageDecl = storageDecl.with(
      \.bindings,
      .init(
        storageDecl.bindings.map { binding in
          binding.with(\.accessorBlock, nil)
        }
      )
    )

    return storageDecl
  }

  /// Creates appropriate type annotation based on backing type
  private static func createTypeAnnotation(
    for type: TypeSyntax,
    backingType: BackingStorageType,
    variableDecl: VariableDeclSyntax
  ) -> TypeSyntax {
    switch backingType {
    case .memory:
      if variableDecl.isWeak {
        return "Stored<Weak<\(type.removingOptionality().trimmed)>>" as TypeSyntax
      } else if variableDecl.isUnowned {
        return "Stored<Unowned<\(type.removingOptionality().trimmed)>>" as TypeSyntax
      } else if variableDecl.isImplicitlyUnwrappedOptional {
        return "Stored<\(type.removingOptionality().trimmed)?>" as TypeSyntax
      } else {
        return "Stored<\(type.trimmed)>" as TypeSyntax
      }
    case .userDefaults:
      return "UserDefaultsStored<\(type.trimmed)>" as TypeSyntax
    }
  }

  /// Creates appropriate initializer based on backing type
  private static func createInitializer(
    for storageDecl: VariableDeclSyntax,
    variableDecl: VariableDeclSyntax,
    backingType: BackingStorageType,
    propertyName: String
  ) -> VariableDeclSyntax {
    switch backingType {
    case .memory:
      return createMemoryInitializer(
        for: storageDecl,
        variableDecl: variableDecl,
        propertyName: propertyName
      )
    case .userDefaults(let config):
      return createUserDefaultsInitializer(
        for: storageDecl,
        variableDecl: variableDecl,
        configuration: config,
        propertyName: propertyName
      )
    }
  }

  /// Creates memory storage initializer
  private static func createMemoryInitializer(
    for storageDecl: VariableDeclSyntax,
    variableDecl: VariableDeclSyntax,
    propertyName: String
  ) -> VariableDeclSyntax {
    if (variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional)
      && !variableDecl.hasInitializer
    {
      let initializerClause: InitializerClauseSyntax
      if variableDecl.isWeak {
        initializerClause = .init(
          value: #".init(name: "\#(raw: propertyName)", wrappedValue: .init(nil))"# as ExprSyntax
        )
      } else if variableDecl.isUnowned {
        initializerClause = .init(
          value: #".init(name: "\#(raw: propertyName)", wrappedValue: .init(nil))"# as ExprSyntax
        )
      } else {
        initializerClause = .init(
          value: #".init(name: "\#(raw: propertyName)", wrappedValue: nil)"# as ExprSyntax
        )
      }
      return storageDecl.addInitializer(initializerClause)
    } else {
      return storageDecl.modifyingInit { initializer in
        if variableDecl.isWeak {
          return .init(
            value:
              #".init(name: "\#(raw: propertyName)", wrappedValue: .init(\#(initializer.trimmed.value)))"#
              as ExprSyntax
          )
        } else if variableDecl.isUnowned {
          return .init(
            value:
              #".init(name: "\#(raw: propertyName)", wrappedValue: .init(\#(initializer.trimmed.value)))"#
              as ExprSyntax
          )
        } else {
          return .init(
            value:
              #".init(name: "\#(raw: propertyName)", wrappedValue: \#(initializer.trimmed.value))"#
              as ExprSyntax
          )
        }
      }
    }
  }

  /// Creates UserDefaults storage initializer
  private static func createUserDefaultsInitializer(
    for storageDecl: VariableDeclSyntax,
    variableDecl: VariableDeclSyntax,
    configuration: BackingStorageType.Configuration,
    propertyName: String
  ) -> VariableDeclSyntax {
    let finalNodeName = configuration.name ?? propertyName

    return storageDecl.modifyingInit { initializer in
      if let suite = configuration.suite {
        return .init(
          value:
            #".init(name: "\#(raw: finalNodeName)", suite: "\#(raw: suite)", key: "\#(raw: configuration.key)", defaultValue: \#(initializer.trimmed.value))"#
            as ExprSyntax
        )
      } else {
        return .init(
          value:
            #".init(name: "\#(raw: finalNodeName)", key: "\#(raw: configuration.key)", defaultValue: \#(initializer.trimmed.value))"#
            as ExprSyntax
        )
      }
    }
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

    // Parse backing storage type
    let backingType = parseBackingStorageType(from: node, context: context)

    // Validate declaration
    guard
      validateDeclaration(
        variableDecl, backingType: backingType, context: context, node: declaration)
    else {
      return []
    }

    // Create storage declaration
    let storageDecl = createStorageDeclaration(
      from: variableDecl,
      backingType: backingType,
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

    // Parse backing storage type
    let backingType = parseBackingStorageType(from: node, context: context)

    return createAccessors(
      propertyName: propertyName,
      variableDecl: variableDecl,
      backingType: backingType,
      context: context
    )
  }

  /// Creates accessor declarations based on backing type
  private static func createAccessors(
    propertyName: String,
    variableDecl: VariableDeclSyntax,
    backingType: BackingStorageType,
    context: some MacroExpansionContext
  ) -> [AccessorDeclSyntax] {
    switch backingType {
    case .memory:
      return createMemoryAccessors(propertyName: propertyName, variableDecl: variableDecl, context: context)
    case .userDefaults:
      return createUserDefaultsAccessors(propertyName: propertyName, variableDecl: variableDecl)
    }
  }

  /// Creates accessor declarations for memory storage
  private static func createMemoryAccessors(
    propertyName: String,
    variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> [AccessorDeclSyntax] {
    let needsInitAccessor = determineIfInitAccessorNeeded(for: variableDecl, context: context)
    var accessors: [AccessorDeclSyntax] = []

    if needsInitAccessor {
      accessors.append(
        createMemoryInitAccessor(propertyName: propertyName, variableDecl: variableDecl))
    } else if !variableDecl.isStatic && !isTopLevelProperty(context: context) {
      // Only add the access-based init accessor for non-static and non-top-level properties
      accessors.append(createMemoryAccessor(propertyName: propertyName, variableDecl: variableDecl))
    }

    accessors.append(
      createMemoryGetAccessor(propertyName: propertyName, variableDecl: variableDecl))
    accessors.append(
      createMemorySetAccessor(propertyName: propertyName, variableDecl: variableDecl))

    return accessors
  }

  /// Creates accessor declarations for UserDefaults storage
  private static func createUserDefaultsAccessors(
    propertyName: String,
    variableDecl: VariableDeclSyntax
  ) -> [AccessorDeclSyntax] {
    var accessors: [AccessorDeclSyntax] = []

    // Add init accessor if no initializer
    if !variableDecl.hasInitializer {
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
      accessors.append(initAccessor)
    }

    // Add getter
    let getter = AccessorDeclSyntax(
      """
      get {
        return $\(raw: propertyName).wrappedValue
      }
      """
    )
    accessors.append(getter)

    // Add setter
    let setter = AccessorDeclSyntax(
      """
      set { 
        $\(raw: propertyName).wrappedValue = newValue
      }
      """
    )
    accessors.append(setter)

    return accessors
  }

  // MARK: - Memory Accessor Helpers

  private static func determineIfInitAccessorNeeded(for variableDecl: VariableDeclSyntax, context: some MacroExpansionContext) -> Bool {
    // Static properties with initializers don't need init accessors
    if variableDecl.isStatic && variableDecl.hasInitializer {
      return false
    }
    
    // Top-level properties with initializers don't need init accessors
    if isTopLevelProperty(context: context) && variableDecl.hasInitializer {
      return false
    }
    
    if variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional {
      return false
    } else {
      return !variableDecl.hasInitializer
    }
  }

  /// Checks if the property is declared at top level (not inside a type)
  private static func isTopLevelProperty(context: some MacroExpansionContext) -> Bool {
    // Check if we're inside a type declaration by looking at the lexical context
    // If we can't find a parent type context, it's likely a top-level property
    let lexicalContext = context.lexicalContext
    
    // Look through the lexical context to see if we're inside a class, struct, enum, etc.
    for syntax in lexicalContext {
      if syntax.is(ClassDeclSyntax.self) ||
         syntax.is(StructDeclSyntax.self) ||
         syntax.is(EnumDeclSyntax.self) ||
         syntax.is(ActorDeclSyntax.self) ||
         syntax.is(ProtocolDeclSyntax.self) ||
         syntax.is(ExtensionDeclSyntax.self) {
        return false // We're inside a type declaration
      }
    }
    
    return true // No parent type found, so it's top-level
  }

  private static func createMemoryInitAccessor(
    propertyName: String,
    variableDecl: VariableDeclSyntax
  ) -> AccessorDeclSyntax {
    if variableDecl.isWeak || variableDecl.isUnowned {
      return AccessorDeclSyntax(
        """
        @storageRestrictions(
          initializes: $\(raw: propertyName)
        )
        init(initialValue) {
          $\(raw: propertyName) = .init(wrappedValue: .init(initialValue))
        }
        """
      )
    } else {
      return AccessorDeclSyntax(
        """
        @storageRestrictions(
          initializes: $\(raw: propertyName)
        )
        init(initialValue) {
          $\(raw: propertyName) = .init(wrappedValue: initialValue)
        }
        """
      )
    }
  }

  private static func createMemoryAccessor(
    propertyName: String,
    variableDecl: VariableDeclSyntax
  ) -> AccessorDeclSyntax {
    if variableDecl.isWeak || variableDecl.isUnowned {
      return AccessorDeclSyntax(
        """
        @storageRestrictions(
          accesses: $\(raw: propertyName)
        )
        init(initialValue) {
          $\(raw: propertyName).wrappedValue.value = initialValue
        }
        """)
    } else {
      return AccessorDeclSyntax(
        """
        @storageRestrictions(
          accesses: $\(raw: propertyName)
        )
        init(initialValue) {
          $\(raw: propertyName).wrappedValue = initialValue
        }
        """)
    }
  }

  private static func createMemoryGetAccessor(
    propertyName: String,
    variableDecl: VariableDeclSyntax
  ) -> AccessorDeclSyntax {
    if variableDecl.isWeak || variableDecl.isUnowned {
      return AccessorDeclSyntax(
        """
        get {
          return $\(raw: propertyName).wrappedValue.value\(raw: variableDecl.isImplicitlyUnwrappedOptional ? "!" : "")
        }
        """
      )
    } else {
      return AccessorDeclSyntax(
        """
        get {
          return $\(raw: propertyName).wrappedValue\(raw: variableDecl.isImplicitlyUnwrappedOptional ? "!" : "")
        }
        """
      )
    }
  }

  private static func createMemorySetAccessor(
    propertyName: String, variableDecl: VariableDeclSyntax
  ) -> AccessorDeclSyntax {
    if variableDecl.isWeak || variableDecl.isUnowned {
      return AccessorDeclSyntax(
        """
        set { 
          $\(raw: propertyName).wrappedValue.value = newValue
        }
        """
      )
    } else {
      return AccessorDeclSyntax(
        """
        set { 
          $\(raw: propertyName).wrappedValue = newValue
        }
        """
      )
    }
  }
}
