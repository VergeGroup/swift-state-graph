import SwiftSyntax
import SwiftSyntaxMacros

/// A protocol that defines the behavior for different backing storage strategies
/// for the @GraphStored macro.
///
/// Each strategy is responsible for:
/// - Validating the variable declaration.
/// - Generating the storage variable declaration (for PeerMacro).
/// - Generating the property accessors (for AccessorMacro).
protocol BackingStorageStrategy {
  /// Validates that the variable declaration is compatible with this storage strategy.
  /// - Parameters:
  ///   - variableDecl: The variable declaration to validate.
  ///   - context: The macro expansion context.
  /// - Returns: `true` if the declaration is valid, `false` otherwise.
  func validate(
    variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> Bool

  /// Creates the backing storage variable declaration.
  /// - Parameters:
  ///   - variableDecl: The original variable declaration.
  ///   - context: The macro expansion context.
  /// - Returns: The new storage variable declaration.
  func makeStorageDeclaration(
    for variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> VariableDeclSyntax

  /// Creates the get/set accessors for the stored property.
  /// - Parameters:
  ///   - variableDecl: The variable declaration.
  ///   - context: The macro expansion context.
  /// - Returns: An array of accessor declarations.
  func makeAccessorDeclarations(
    for variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> [AccessorDeclSyntax]
}
