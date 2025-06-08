//
//  BookTerminalColorSchemeEditor.swift
//  iOS18Play
//
//  Created by Muukii on 2025/06/07.
//

import SwiftUI
import StateGraph

struct ANSIColorScheme: Codable, UserDefaultsStorable {
  var black: Color = .black
  var red: Color = .red
  var green: Color = .green
  var yellow: Color = .yellow
  var blue: Color = .blue
  var magenta: Color = .purple
  var cyan: Color = .cyan
  var white: Color = .white
  var brightBlack: Color = .gray
  var brightRed: Color = Color(red: 1.0, green: 0.4, blue: 0.4)
  var brightGreen: Color = Color(red: 0.4, green: 1.0, blue: 0.4)
  var brightYellow: Color = Color(red: 1.0, green: 1.0, blue: 0.4)
  var brightBlue: Color = Color(red: 0.4, green: 0.4, blue: 1.0)
  var brightMagenta: Color = Color(red: 1.0, green: 0.4, blue: 1.0)
  var brightCyan: Color = Color(red: 0.4, green: 1.0, blue: 1.0)
  var brightWhite: Color = Color(red: 0.9, green: 0.9, blue: 0.9)
  
  var background: Color = .black
  var foreground: Color = .white
}

extension Color: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let red = try container.decode(Double.self, forKey: .red)
    let green = try container.decode(Double.self, forKey: .green)
    let blue = try container.decode(Double.self, forKey: .blue)
    let alpha = try container.decode(Double.self, forKey: .alpha)
    self.init(red: red, green: green, blue: blue, opacity: alpha)
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let uiColor = UIColor(self)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    try container.encode(Double(red), forKey: .red)
    try container.encode(Double(green), forKey: .green)
    try container.encode(Double(blue), forKey: .blue)
    try container.encode(Double(alpha), forKey: .alpha)
  }
  
  private enum CodingKeys: String, CodingKey {
    case red, green, blue, alpha
  }
}

final class TerminalColorSchemeStore: GraphObject {
  @GraphStored(backed: .userDefaults(key: "terminalColorScheme")) 
  var colorScheme: ANSIColorScheme = ANSIColorScheme()
}

private struct ColorPickerRow: View {
  let title: String
  @Binding var color: Color
  
  var body: some View {
    HStack {
      Text(title)
        .frame(width: 120, alignment: .leading)
      ColorPicker("", selection: $color)
        .labelsHidden()
    }
  }
}

struct TerminalPreview: View {
  let colorScheme: ANSIColorScheme
  
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Terminal Preview")
        .font(.headline)
        .padding(.bottom, 8)
      
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 0) {
          Text("user@hostname:~$ ")
            .foregroundColor(colorScheme.green)
          Text("ls -la")
            .foregroundColor(colorScheme.foreground)
        }
        
        Text("total 64")
          .foregroundColor(colorScheme.foreground)
        
        HStack(spacing: 0) {
          Text("drwxr-xr-x")
            .foregroundColor(colorScheme.blue)
          Text("  5 user  staff   160 ")
            .foregroundColor(colorScheme.foreground)
          Text("Dec  7 10:30 ")
            .foregroundColor(colorScheme.cyan)
          Text("Documents")
            .foregroundColor(colorScheme.blue)
        }
        
        HStack(spacing: 0) {
          Text("-rw-r--r--")
            .foregroundColor(colorScheme.foreground)
          Text("  1 user  staff  1024 ")
            .foregroundColor(colorScheme.foreground)
          Text("Dec  7 09:15 ")
            .foregroundColor(colorScheme.cyan)
          Text("README.md")
            .foregroundColor(colorScheme.foreground)
        }
        
        HStack(spacing: 0) {
          Text("-rwxr-xr-x")
            .foregroundColor(colorScheme.green)
          Text("  1 user  staff  2048 ")
            .foregroundColor(colorScheme.foreground)
          Text("Dec  6 14:22 ")
            .foregroundColor(colorScheme.cyan)
          Text("script.sh")
            .foregroundColor(colorScheme.green)
        }
        
        HStack(spacing: 0) {
          Text("user@hostname:~$ ")
            .foregroundColor(colorScheme.green)
          Text("echo ")
            .foregroundColor(colorScheme.foreground)
          Text("\"")
            .foregroundColor(colorScheme.yellow)
          Text("Hello, World!")
            .foregroundColor(colorScheme.yellow)
          Text("\"")
            .foregroundColor(colorScheme.yellow)
        }
        
        Text("Hello, World!")
          .foregroundColor(colorScheme.foreground)
        
        HStack(spacing: 0) {
          Text("user@hostname:~$ ")
            .foregroundColor(colorScheme.green)
          Text("■")
            .foregroundColor(colorScheme.foreground)
            .blinking()
        }
      }
    }
    .font(.system(.body, design: .monospaced))
    .padding()
    .background(colorScheme.background)
    .border(Color.gray, width: 1)
  }
}

extension View {
  func blinking(duration: Double = 1.0) -> some View {
    self.opacity(0.3)
      .animation(.easeInOut(duration: duration).repeatForever(), value: UUID())
  }
}

struct TerminalColorDesigner: View {
  let store = TerminalColorSchemeStore()
  
  var body: some View {
    VStack(spacing: 20) {
      TerminalPreview(colorScheme: store.colorScheme)
      
      VStack(spacing: 16) {
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 8) {
            Text("ANSI Colors")
              .font(.headline)
            
            Group {
              ColorPickerRow(title: "Black", color: store.$colorScheme.binding.black)
              ColorPickerRow(title: "Red", color: store.$colorScheme.binding.red)
              ColorPickerRow(title: "Green", color: store.$colorScheme.binding.green)
              ColorPickerRow(title: "Yellow", color: store.$colorScheme.binding.yellow)
              ColorPickerRow(title: "Blue", color: store.$colorScheme.binding.blue)
              ColorPickerRow(title: "Magenta", color: store.$colorScheme.binding.magenta)
              ColorPickerRow(title: "Cyan", color: store.$colorScheme.binding.cyan)
              ColorPickerRow(title: "White", color: store.$colorScheme.binding.white)
            }
          }
          
          VStack(alignment: .leading, spacing: 8) {
            Text("Bright Colors")
              .font(.headline)
            
            Group {
              ColorPickerRow(title: "Bright Black", color: store.$colorScheme.binding.brightBlack)
              ColorPickerRow(title: "Bright Red", color: store.$colorScheme.binding.brightRed)
              ColorPickerRow(title: "Bright Green", color: store.$colorScheme.binding.brightGreen)
              ColorPickerRow(title: "Bright Yellow", color: store.$colorScheme.binding.brightYellow)
              ColorPickerRow(title: "Bright Blue", color: store.$colorScheme.binding.brightBlue)
              ColorPickerRow(title: "Bright Magenta", color: store.$colorScheme.binding.brightMagenta)
              ColorPickerRow(title: "Bright Cyan", color: store.$colorScheme.binding.brightCyan)
              ColorPickerRow(title: "Bright White", color: store.$colorScheme.binding.brightWhite)
            }
          }
        }
        
        VStack(alignment: .leading, spacing: 8) {
          Text("Terminal")
            .font(.headline)
          
          HStack(spacing: 40) {
            ColorPickerRow(title: "Background", color: store.$colorScheme.binding.background)
            ColorPickerRow(title: "Foreground", color: store.$colorScheme.binding.foreground)
          }
        }
      }
      .padding()
    }
    .padding()
  }
}

#Preview("TerminalColorScheme") {
  TerminalColorDesigner()
}
