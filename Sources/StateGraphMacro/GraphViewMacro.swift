import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct GraphViewMacro: Macro {

  public enum Error: Swift.Error {
    case needsTypeAnnotation
    case notFoundPropertyName
  }

  public static var formatMode: FormatMode {
    .auto
  }

}

extension GraphViewMacro: MemberAttributeMacro {

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
        "@GraphStored",
        "@GraphComputed",
        "@GraphIgnored",
      ]
    )

    if existingAttributes.filter({ ignoreMacros.contains($0) }).count > 0 {
      return []
    }

    guard variableDecl.bindingSpecifier.tokenKind == .keyword(.var) else {
      return []
    }

    if variableDecl.isComputed {
      return [
      ]
    } else {
      return [AttributeSyntax(stringLiteral: "@GraphStored")]
    }

  }
}

extension GraphViewMacro: MemberMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    return []
  }

}

extension GraphViewMacro: ExtensionMacro {
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
      extension \(classDecl.name.trimmed): GraphViewType {      
      }
      """ as DeclSyntax).cast(ExtensionDeclSyntax.self)
    ]
  }
}
