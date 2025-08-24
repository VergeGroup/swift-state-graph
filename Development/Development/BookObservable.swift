import SwiftUI

import SwiftUI

private struct _Book: View {
  
  let model: ObservableModel = .init()
  
  var body: some View {
    Form {
      Button("Up Count1") {
        model.count1 += 1
      }
      Button("Up Count2") {
        model.count2 += 1
      }
    }
    .onAppear {
      
      withObservationTracking { 
        _ = model.count1
        _ = model.count2
      } onChange: { 
        print(
          "change"
        )
      }
      
    }
  }
}

@Observable
fileprivate class ObservableModel {
  
  var count1: Int = 0
  var count2: Int = 0
}

#Preview("BookObservable") {
  _Book()
}
