import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct UnifiedStoredMacro {}

extension UnifiedStoredMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {

    guard let variableDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }

    if SyntaxHelpers.shouldIgnoreMacro(variableDecl) || variableDecl.isComputed {
      return []
    }

    let strategy = BackingStorageFactory.makeStrategy(from: node, context: context)

    guard strategy.validate(variableDecl: variableDecl, context: context) else {
      return []
    }

    let storageDecl = strategy.makeStorageDeclaration(for: variableDecl, context: context)
    return [DeclSyntax(storageDecl)]
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

    // Common validations for accessors
    if variableDecl.isComputed {
      context.addDiagnostics(from: MacroError.computedVariableIsNotSupported, node: declaration)
      return []
    }
    if variableDecl.isConstant {
      context.addDiagnostics(from: MacroError.constantVariableIsNotSupported, node: declaration)
      return []
    }
    if variableDecl.isWeak {
      context.addDiagnostics(from: MacroError.weakVariableNotSupported, node: declaration)
      return []
    }
    if variableDecl.isUnowned {
      context.addDiagnostics(from: MacroError.unownedVariableNotSupported, node: declaration)
      return []
    }

    let strategy = BackingStorageFactory.makeStrategy(from: node, context: context)
    return strategy.makeAccessorDeclarations(for: variableDecl, context: context)
  }
}