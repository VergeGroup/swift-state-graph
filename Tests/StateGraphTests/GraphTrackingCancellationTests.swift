import Foundation
import Testing

@testable import StateGraph

@Suite("GraphTrackingCancellation Tests")
struct GraphTrackingCancellationTests {
  
  final class Resource {
    deinit {
      
    }
  }
  
  @Test
  func resourceReleasingGroup() {

    let node = Stored(wrappedValue: 0)

    let pointer = Unmanaged.passRetained(Resource())

    weak var resourceRef: Resource? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingGroup { [resource = pointer.takeUnretainedValue()] in
        print(node.wrappedValue)
        print(resource)
      }
    }

    pointer.release()

    #expect(resourceRef != nil)

    subscription.cancel()

    #expect(resourceRef == nil)

  }

  @Test
  func resourceReleasingMap() {

    let node = Stored(wrappedValue: 0)

    let pointer = Unmanaged.passRetained(Resource())

    weak var resourceRef: Resource? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingMap(
        { [resource = pointer.takeUnretainedValue()] in
          print(node.wrappedValue)
          print(resource)
          return node.wrappedValue
        }
      ) { value in
        print("Value: \(value)")
      }
    }

    pointer.release()

    #expect(resourceRef != nil)

    subscription.cancel()

    #expect(resourceRef == nil)

  }

  @Test
  func resourceReleasingMapDependency() {

    class ViewModel {
      let node = Stored(wrappedValue: 0)
    }

    let viewModel = ViewModel()

    let pointer = Unmanaged.passRetained(Resource())

    weak var resourceRef: Resource? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingMap(
        from: viewModel,
        map: { [resource = pointer.takeUnretainedValue()] vm in
          print(vm.node.wrappedValue)
          print(resource)
          return vm.node.wrappedValue
        }
      ) { value in
        print("Value: \(value)")
      }
    }

    pointer.release()

    #expect(resourceRef != nil)

    subscription.cancel()

    #expect(resourceRef == nil)

  }

  @Test
  func resourceReleasingMapDependencyOnChange() {

    class ViewModel {
      let node = Stored(wrappedValue: 0)
    }

    let viewModel = ViewModel()

    let pointer = Unmanaged.passRetained(Resource())

    weak var resourceRef: Resource? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingMap(
        from: viewModel,
        map: { vm in vm.node.wrappedValue }
      ) { [resource = pointer.takeUnretainedValue()] value in
        print("Value: \(value)")
        print(resource)
      }
    }

    pointer.release()

    #expect(resourceRef != nil)

    subscription.cancel()

    #expect(resourceRef == nil)

  }

  @Test
  func viewModelNotRetained() {

    class ViewModel {
      let node = Stored(wrappedValue: 0)
      deinit {
        print("ViewModel deinit")
      }
    }

    let pointer = Unmanaged.passRetained(ViewModel())

    weak var viewModelRef: ViewModel? = pointer.takeUnretainedValue()

    let subscription = withGraphTracking {
      withGraphTrackingMap(
        from: pointer.takeUnretainedValue(),
        map: { vm in vm.node.wrappedValue }
      ) { value in
        print("Value: \(value)")
      }
    }

    // viewModel should be retained only by pointer, not by withGraphTrackingMap
    #expect(viewModelRef != nil)

    pointer.release()

    // After releasing, viewModel should be deallocated
    // because withGraphTrackingMap doesn't retain it
    #expect(viewModelRef == nil)

    subscription.cancel()

  }

}
