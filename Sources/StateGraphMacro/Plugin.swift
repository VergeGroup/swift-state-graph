import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct Plugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    FragmentMacro.self,
    StoredMacro.self,
    ComputedMacro.self,
    IgnoredMacro.self,
    ComputedMacro.self,
  ]
}
