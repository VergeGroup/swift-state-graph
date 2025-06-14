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

    // Find the 'backed' argument
    guard let backedArgument = arguments.first(where: { $0.label?.text == "backed" }) else {
      return .memory
    }
    
    return parseBackingExpression(from: backedArgument.expression)
  }
  
  /// Parses the backing expression to determine storage type
  private static func parseBackingExpression(
    from expression: ExprSyntax
  ) -> BackingStorageType {
    // Handle function call like .userDefaults(key: "key")
    if let functionCall = expression.as(FunctionCallExprSyntax.self),
       let callee = functionCall.calledExpression.as(MemberAccessExprSyntax.self),
       callee.declName.baseName.text == "userDefaults" {
      let config = parseUserDefaultsArguments(from: functionCall.arguments)
      return .userDefaults(config)
    }
    
    // Handle member access like .memory
    if let memberAccess = expression.as(MemberAccessExprSyntax.self),
       memberAccess.declName.baseName.text == "memory" {
      return .memory
    }
    
    // Default to memory for any unrecognized expression
    return .memory
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

// MARK: - Initializer Builder

extension UnifiedStoredMacro {
  
  /// Builder for creating storage initializer expressions
  struct InitializerBuilder {
    let propertyName: String
    let wrappedValue: String
    let suite: String?
    let key: String?
    
    func buildMemoryInitializer() -> ExprSyntax {
      return #".init(name: "\#(raw: propertyName)", wrappedValue: \#(raw: wrappedValue))"# as ExprSyntax
    }
    
    func buildUserDefaultsInitializer() -> ExprSyntax {
      guard let key = key else {
        fatalError("UserDefaults initializer requires a key")
      }
      
      if let suite = suite {
        return #".init(name: "\#(raw: propertyName)", suite: "\#(raw: suite)", key: "\#(raw: key)", defaultValue: \#(raw: wrappedValue))"# as ExprSyntax
      } else {
        return #".init(name: "\#(raw: propertyName)", key: "\#(raw: key)", defaultValue: \#(raw: wrappedValue))"# as ExprSyntax
      }
    }
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
      return createMemoryTypeAnnotation(for: type, variableDecl: variableDecl)
    case .userDefaults:
      return "UserDefaultsStored<\(type.trimmed)>" as TypeSyntax
    }
  }
  
  /// Creates memory storage type annotation
  private static func createMemoryTypeAnnotation(
    for type: TypeSyntax,
    variableDecl: VariableDeclSyntax
  ) -> TypeSyntax {
    let baseType = type.removingOptionality().trimmed
    
    // Determine wrapper type based on variable modifiers
    let wrappedType: String
    if variableDecl.isWeak {
      wrappedType = "Weak<\(baseType)>"
    } else if variableDecl.isUnowned {
      wrappedType = "Unowned<\(baseType)>"
    } else if variableDecl.isImplicitlyUnwrappedOptional {
      wrappedType = "\(baseType)?"
    } else {
      wrappedType = "\(type.trimmed)"
    }
    
    return "Stored<\(raw: wrappedType)>" as TypeSyntax
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
    let needsWrapper = needsValueAccess(variableDecl)
    
    if (variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional)
      && !variableDecl.hasInitializer
    {
      let wrappedValue = createWrapperInitExpression("nil", needsWrapper: needsWrapper)
      let builder = InitializerBuilder(
        propertyName: propertyName,
        wrappedValue: wrappedValue,
        suite: nil,
        key: nil
      )
      return storageDecl.addInitializer(
        InitializerClauseSyntax(value: builder.buildMemoryInitializer())
      )
    } else {
      return storageDecl.modifyingInit { initializer in
        let wrappedValue = createWrapperInitExpression(
          "\(initializer.trimmed.value)",
          needsWrapper: needsWrapper
        )
        let builder = InitializerBuilder(
          propertyName: propertyName,
          wrappedValue: wrappedValue,
          suite: nil,
          key: nil
        )
        return .init(value: builder.buildMemoryInitializer())
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
      let builder = InitializerBuilder(
        propertyName: finalNodeName,
        wrappedValue: "\(initializer.trimmed.value)",
        suite: configuration.suite,
        key: configuration.key
      )
      
      return .init(value: builder.buildUserDefaultsInitializer())
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
      accessors.append(createStorageRestrictionsInitAccessor(
        propertyName: propertyName,
        body: "// This should be handled by PeerMacro\nfatalError(\"UserDefaultsStored requires default value\")"
      ))
    }

    // Add getter and setter
    accessors.append(createSimpleGetAccessor(propertyName: propertyName))
    accessors.append(createSimpleSetAccessor(propertyName: propertyName))

    return accessors
  }
  
  // MARK: - Common Accessor Helpers
  
  private static func createStorageRestrictionsInitAccessor(
    propertyName: String,
    body: String
  ) -> AccessorDeclSyntax {
    return AccessorDeclSyntax(
      """
      @storageRestrictions(
        initializes: $\(raw: propertyName)
      )
      init(initialValue) {
        \(raw: body)
      }
      """
    )
  }
  
  private static func createSimpleGetAccessor(
    propertyName: String
  ) -> AccessorDeclSyntax {
    return AccessorDeclSyntax(
      """
      get {
        return $\(raw: propertyName).wrappedValue
      }
      """
    )
  }
  
  private static func createSimpleSetAccessor(
    propertyName: String
  ) -> AccessorDeclSyntax {
    return AccessorDeclSyntax(
      """
      set { 
        $\(raw: propertyName).wrappedValue = newValue
      }
      """
    )
  }

  // MARK: - Memory Accessor Helpers
  
  /// Helper to determine if we need to access through .value for weak/unowned references
  private static func needsValueAccess(_ variableDecl: VariableDeclSyntax) -> Bool {
    return variableDecl.isWeak || variableDecl.isUnowned
  }
  
  /// Helper to create wrapper initialization expression
  private static func createWrapperInitExpression(
    _ value: String,
    needsWrapper: Bool
  ) -> String {
    return needsWrapper ? ".init(\(value))" : value
  }
  
  /// Helper to create value access expression
  private static func createValueAccessExpression(
    propertyName: String,
    needsValueAccess: Bool,
    needsUnwrap: Bool = false
  ) -> String {
    let base = "$\(propertyName).wrappedValue"
    let accessed = needsValueAccess ? "\(base).value" : base
    return needsUnwrap ? "\(accessed)!" : accessed
  }

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
    let wrappedValue = createWrapperInitExpression(
      "initialValue", 
      needsWrapper: needsValueAccess(variableDecl)
    )
    
    return AccessorDeclSyntax(
      """
      @storageRestrictions(
        initializes: $\(raw: propertyName)
      )
      init(initialValue) {
        $\(raw: propertyName) = .init(wrappedValue: \(raw: wrappedValue))
      }
      """
    )
  }

  private static func createMemoryAccessor(
    propertyName: String,
    variableDecl: VariableDeclSyntax
  ) -> AccessorDeclSyntax {
    let assignmentTarget = needsValueAccess(variableDecl) 
      ? "$\(propertyName).wrappedValue.value"
      : "$\(propertyName).wrappedValue"
    
    return AccessorDeclSyntax(
      """
      @storageRestrictions(
        accesses: $\(raw: propertyName)
      )
      init(initialValue) {
        \(raw: assignmentTarget) = initialValue
      }
      """)
  }

  private static func createMemoryGetAccessor(
    propertyName: String,
    variableDecl: VariableDeclSyntax
  ) -> AccessorDeclSyntax {
    let valueExpression = createValueAccessExpression(
      propertyName: propertyName,
      needsValueAccess: needsValueAccess(variableDecl),
      needsUnwrap: variableDecl.isImplicitlyUnwrappedOptional
    )
    
    return AccessorDeclSyntax(
      """
      get {
        return \(raw: valueExpression)
      }
      """
    )
  }

  private static func createMemorySetAccessor(
    propertyName: String, variableDecl: VariableDeclSyntax
  ) -> AccessorDeclSyntax {
    let assignmentTarget = needsValueAccess(variableDecl)
      ? "$\(propertyName).wrappedValue.value"
      : "$\(propertyName).wrappedValue"
    
    return AccessorDeclSyntax(
      """
      set { 
        \(raw: assignmentTarget) = newValue
      }
      """
    )
  }
}
