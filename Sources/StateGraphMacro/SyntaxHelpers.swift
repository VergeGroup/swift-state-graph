import SwiftSyntax
import SwiftSyntaxMacros

enum SyntaxHelpers {
  /// Extracts string literal value from expression
  static func extractStringLiteral(from expression: ExprSyntax) -> String? {
    guard let stringLiteral = expression.as(StringLiteralExprSyntax.self),
      let segment = stringLiteral.segments.first?.as(StringSegmentSyntax.self)
    else {
      return nil
    }
    return segment.content.text
  }

  /// Checks if the property is declared at top level (not inside a type)
  static func isTopLevelProperty(context: some MacroExpansionContext) -> Bool {
    for syntax in context.lexicalContext {
      if syntax.is(ClassDeclSyntax.self) ||
         syntax.is(StructDeclSyntax.self) ||
         syntax.is(EnumDeclSyntax.self) ||
         syntax.is(ActorDeclSyntax.self) ||
         syntax.is(ProtocolDeclSyntax.self) ||
         syntax.is(ExtensionDeclSyntax.self) {
        return false
      }
    }
    return true
  }
  
  /// Checks if the macro should be ignored
  static func shouldIgnoreMacro(_ variableDecl: VariableDeclSyntax) -> Bool {
    return variableDecl.attributes.contains {
      switch $0 {
      case .attribute(let attribute):
        return attribute.attributeName.description == "Ignored"
      case .ifConfigDecl:
        return false
      }
    }
  }
}
