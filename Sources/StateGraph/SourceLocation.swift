
/// Represents the location in the source code where a node was created.
public struct SourceLocation: ~Copyable, Sendable {
  
  /// The file path.
  public let file: StaticString
  /// The line number.
  public let line: UInt
  /// The column number.
  public let column: UInt
  
  /// Creates a new location.
  public init(file: StaticString, line: UInt, column: UInt) {
    self.file = file
    self.line = line
    self.column = column
  }
  
  /// Returns a formatted representation ``file:line:column``.
  public var text: String {
    "\(file):\(line):\(column)"
  }
  
}

/// Metadata describing a node instance.
public struct NodeInfo: ~Copyable, Sendable {
  
  /// Optional group used for debugging.
  public let group: String?
  /// Optional user-defined name.
  public let name: String?
  /// Concrete type name of the node's value.
  public let typeName: String
  /// Unique identifier of the node.
  public let id: UInt64
  
  /// Source location where the node was created.
  public let sourceLocation: SourceLocation
 
  init<T>(
    type: T.Type,
    group: String? = nil,
    name: String? = nil,
    id: UInt64,
    sourceLocation: consuming SourceLocation
  ) {
    self.group = group
    self.name = name
    self.id = id
    self.typeName = _typeName(type)
    self.sourceLocation = sourceLocation    
  }
}
