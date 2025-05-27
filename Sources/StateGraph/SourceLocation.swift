
public struct SourceLocation: ~Copyable, Sendable {
  
  public let file: StaticString
  public let line: UInt
  public let column: UInt
  
  public init(file: StaticString, line: UInt, column: UInt) {
    self.file = file
    self.line = line
    self.column = column
  }
  
  public var text: String {
    "\(file):\(line):\(column)"
  }
  
}

public struct NodeInfo: ~Copyable, Sendable {
  
  public let name: StaticString?
  public let sourceLocation: SourceLocation
 
  init(    
    name: StaticString? = nil,
    sourceLocation: consuming SourceLocation
  ) {
    self.name = name
    self.sourceLocation = sourceLocation    
  }
}
