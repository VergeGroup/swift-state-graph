import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct StoredMacro {
  public enum Error: Swift.Error {
    case needsTypeAnnotation
  }
}

extension StoredMacro: PeerMacro {
  
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
    
    let isPublic = variableDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) })
    let isPrivate = variableDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.private) })
    
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
    
    var _variableDecl = variableDecl.trimmed
    _variableDecl.attributes = [.init(.init(stringLiteral: "@Ignored"))]
    _variableDecl = _variableDecl.with(\.modifiers, [.init(name: .keyword(.private))])
    
    if variableDecl.isOptional {
      _variableDecl =
      _variableDecl
        .renamingIdentifier(with: "_backing_")
        .modifyingTypeAnnotation({ type in
          return "StateNode<\(type.trimmed)>?"
        })
      
//      // add init
//      _variableDecl = _variableDecl.with(
//        \.bindings,
//         .init(
//          _variableDecl.bindings.map { binding in
//            binding.with(\.initializer, .init(value: "StateNode.init(nil)" as ExprSyntax))
//          })
//      )
      
    } else {
      _variableDecl =
      _variableDecl
        .renamingIdentifier(with: "_backing_")
        .modifyingTypeAnnotation({ type in
          return "StateNode<\(type.trimmed)>?"
        })
//        .modifyingInit({ initializer in
//          return .init(value: "StateNode.init(\(initializer.trimmed.value))" as ExprSyntax)
//        })
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

extension StoredMacro: AccessorMacro {
  
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
    
    if variableDecl.isComputed {
      
      let originalBlock = variableDecl.getBlock
            
      let readAccessor = AccessorDeclSyntax(
      """
      {            
        if let _backing_\(raw: propertyName) {
          return _backing_\(raw: propertyName).wrappedValue
        }
        let node = stateGraph.rule(name: "\(raw: propertyName)") { [self] in
          \(originalBlock)
        }
        self._backing_\(raw: propertyName) = node
        return node.wrappedValue
      }
      """
      )
            
      var accessors: [AccessorDeclSyntax] = []
      
      accessors.append(readAccessor)
      
      
      return accessors
      
    } else {
      
      let isConstant = variableDecl.bindingSpecifier.tokenKind == .keyword(.let)
      let backingName = "_backing_" + propertyName
      let hasDidSet = variableDecl.didSetBlock != nil
      let hasWillSet = variableDecl.willSetBlock != nil
      
      let initAccessor = AccessorDeclSyntax(
      """
      @storageRestrictions(
        accesses: stateGraph,
        initializes: _backing_\(raw: propertyName)
      )
      init(initialValue) {
        _backing_\(raw: propertyName) = stateGraph.input(name: "\(raw: propertyName)", initialValue)
      }
      """
      )
      
      let readAccessor = AccessorDeclSyntax(
      """
      get {            
        _backing_\(raw: propertyName)!.wrappedValue
      }
      """
      )
      
      let setAccessor = AccessorDeclSyntax(
      """
      set { 
        _backing_\(raw: propertyName)!.wrappedValue = newValue      
      }
      """
      )
           
      var accessors: [AccessorDeclSyntax] = []
      
      if binding.initializer == nil {
        accessors.append(initAccessor)
      }
      
      accessors.append(readAccessor)
      
      if !isConstant {
        accessors.append(setAccessor)             
      }
      
      return accessors
    }
  }

  
}

extension VariableDeclSyntax {
  
  var isOptional: Bool {
    
    return self.bindings.contains(where: {
      $0.typeAnnotation?.type.is(OptionalTypeSyntax.self) ?? false
    })
    
  }
  
  var typeSyntax: TypeSyntax? {
    return self.bindings.first?.typeAnnotation?.type    
  }
  
  func modifyingTypeAnnotation(_ modifier: (TypeSyntax) -> TypeSyntax) -> VariableDeclSyntax {
    let newBindings = self.bindings.map { binding -> PatternBindingSyntax in
      if let typeAnnotation = binding.typeAnnotation {
        let newType = modifier(typeAnnotation.type)
        let newTypeAnnotation = typeAnnotation.with(\.type, newType)
        return binding.with(\.typeAnnotation, newTypeAnnotation)
      }
      return binding
    }
    
    return self.with(\.bindings, .init(newBindings))
  }
  
  func modifyingInit(_ modifier: (InitializerClauseSyntax) -> InitializerClauseSyntax)
  -> VariableDeclSyntax
  {
    
    let newBindings = self.bindings.map { binding -> PatternBindingSyntax in
      if let initializer = binding.initializer {
        let newInitializer = modifier(initializer)
        return binding.with(\.initializer, newInitializer)
      }
      return binding
    }
    
    return self.with(\.bindings, .init(newBindings))
  }
  
  var name: String {
    return self.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? ""
  }
  
  func renamingIdentifier(with newName: String) -> VariableDeclSyntax {
    let newBindings = self.bindings.map { binding -> PatternBindingSyntax in
      
      if let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) {
        
        let propertyName = identifierPattern.identifier.text
        
        let newIdentifierPattern = identifierPattern.with(
          \.identifier, "\(raw: newName)\(raw: propertyName)")
        return binding.with(\.pattern, .init(newIdentifierPattern))
      }
      return binding
    }
    
    return self.with(\.bindings, .init(newBindings))
  }
  
  
  func makeDidSetDoBlock() -> DoStmtSyntax {
    guard let didSetBlock = self.didSetBlock else {
      return .init(body: "{}")
    }
    
    return .init(body: didSetBlock)    
  }
  
  func makeWillSetDoBlock() -> DoStmtSyntax {
    guard let willSetBlock = self.willSetBlock else {
      return .init(body: "{}")
    }
    
    return .init(body: willSetBlock)    
  }
  
  var getBlock: CodeBlockItemListSyntax? {
    for binding in self.bindings {
      if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
          for accessor in accessors {
            if accessor.accessorSpecifier.tokenKind == .keyword(.get) {
              return accessor.body?.statements
            }
          }
        case .getter(let codeBlock):
          return codeBlock
        }       
      }
    }
    return nil
  }
  
  var didSetBlock: CodeBlockSyntax? {
    for binding in self.bindings {
      if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
          for accessor in accessors {
            if accessor.accessorSpecifier.tokenKind == .keyword(.didSet) {
              return accessor.body
            }
          }
        case .getter(let _):
          return nil
        }       
      }
    }
    return nil
  }
  
  var willSetBlock: CodeBlockSyntax? {
    for binding in self.bindings {
      if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
          for accessor in accessors {
            if accessor.accessorSpecifier.tokenKind == .keyword(.willSet) {
              return accessor.body
            }
          }
        case .getter(let _):
          return nil
        }       
      }
    }
    return nil
  }
  
  var isComputed: Bool {
    for binding in self.bindings {
      if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
          for accessor in accessors {
            if accessor.accessorSpecifier.tokenKind == .keyword(.get) {
              return true
            }
          }
        case .getter:
          return true
        }
      }
    }
    return false
  }
}
