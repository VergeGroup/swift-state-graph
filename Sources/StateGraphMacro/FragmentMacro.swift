
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct FragmentMacro: Macro {
  
  public enum Error: Swift.Error {
    case needsTypeAnnotation
    case notFoundPropertyName
  }
  
  public static var formatMode: FormatMode {
    .auto
  }
  
}

extension FragmentMacro: MemberAttributeMacro {
  
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingAttributesFor member: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AttributeSyntax] {
  
    guard let variableDecl = member.as(VariableDeclSyntax.self) else {
      return []
    }
    
    let existingAttributes = variableDecl.attributes.map { $0.trimmed.description }
    
    let ignoreMacros = Set(
      [
        "@Node",
        "@WeakNode",
      ]
    )
    
    if existingAttributes.filter({ ignoreMacros.contains($0) }).count > 0 {
      return []
    }
                
    guard variableDecl.bindingSpecifier.tokenKind == .keyword(.var) else {
      return []
    }
    
    let isWeak = variableDecl.modifiers.contains { modifier in
      modifier.name.tokenKind == .keyword(.weak)
    }
    
    if variableDecl.isComputed {      
      return [AttributeSyntax(stringLiteral: "@Computed")]
    } else {          
      if isWeak {
        return [AttributeSyntax(stringLiteral: "@StoredWeak")]
      } else {
        return [AttributeSyntax(stringLiteral: "@Stored")]
      }
    }
    
  }
}

extension FragmentMacro: MemberMacro {
  
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let isPublic = declaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) })
    
    return [
      """
      \(raw: isPublic ? "public" : "internal") var stateGraph: StateGraph
      """ as DeclSyntax
    ]
  }
    
}

extension FragmentMacro: ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    
    guard let classDecl = declaration.as(ClassDeclSyntax.self) else {
      fatalError()
    }
    
    return [
      ("""
      extension \(classDecl.name.trimmed): StateFragment {      
      }
      """ as DeclSyntax).cast(ExtensionDeclSyntax.self)
    ]
  }
}
