import Foundation
import Testing
@testable import StateGraph

@Suite("@GraphStored property observers")
struct GraphStoredDidSetTests {

  @Test func didSet_runs_after_assignment_with_old_value() {
    final class Model {
      @GraphStored
      var count: Int = 0 {
        didSet {
          history.append((oldValue, count))
        }
      }

      var history: [(Int, Int)] = []
    }

    let model = Model()

    model.count = 1
    model.count = 3

    #expect(model.history.count == 2)
    #expect(model.history[0].0 == 0)
    #expect(model.history[0].1 == 1)
    #expect(model.history[1].0 == 1)
    #expect(model.history[1].1 == 3)
  }

  @Test func didSet_uses_custom_old_value_name() {
    final class Model {
      @GraphStored
      var count: Int = 10 {
        didSet(previousValue) {
          history.append((previousValue, count))
        }
      }

      var history: [(Int, Int)] = []
    }

    let model = Model()

    model.count = 12

    #expect(model.history.count == 1)
    #expect(model.history[0].0 == 10)
    #expect(model.history[0].1 == 12)
  }

  @Test func didSet_runs_with_userDefaults_backing() {
    let key = "GraphStoredDidSetTests.username"
    UserDefaults.standard.removeObject(forKey: key)

    final class Settings {
      @GraphStored(backed: .userDefaults(key: "GraphStoredDidSetTests.username"))
      var username: String = "anonymous" {
        didSet {
          history.append((oldValue, username))
        }
      }

      var history: [(String, String)] = []
    }

    let settings = Settings()

    settings.username = "blob"

    #expect(settings.history.count == 1)
    #expect(settings.history[0].0 == "anonymous")
    #expect(settings.history[0].1 == "blob")

    UserDefaults.standard.removeObject(forKey: key)
  }

  @Test func willSet_runs_before_assignment_with_new_value() {
    final class Model {
      @GraphStored
      var count: Int = 0 {
        willSet {
          history.append((count, newValue))
        }
      }

      var history: [(Int, Int)] = []
    }

    let model = Model()

    model.count = 2

    #expect(model.history.count == 1)
    #expect(model.history[0].0 == 0)
    #expect(model.history[0].1 == 2)
    #expect(model.count == 2)
  }

  @Test func willSet_uses_custom_new_value_name() {
    final class Model {
      @GraphStored
      var count: Int = 5 {
        willSet(nextValue) {
          history.append((count, nextValue))
        }
      }

      var history: [(Int, Int)] = []
    }

    let model = Model()

    model.count = 8

    #expect(model.history.count == 1)
    #expect(model.history[0].0 == 5)
    #expect(model.history[0].1 == 8)
    #expect(model.count == 8)
  }

  @Test func willSet_and_didSet_run_in_observer_order() {
    final class Model {
      @GraphStored
      var count: Int = 0 {
        willSet {
          history.append(("will", count, newValue))
        }
        didSet {
          history.append(("did", oldValue, count))
        }
      }

      var history: [(String, Int, Int)] = []
    }

    let model = Model()

    model.count = 4

    #expect(model.history.count == 2)
    #expect(model.history[0].0 == "will")
    #expect(model.history[0].1 == 0)
    #expect(model.history[0].2 == 4)
    #expect(model.history[1].0 == "did")
    #expect(model.history[1].1 == 0)
    #expect(model.history[1].2 == 4)
  }

  @Test func willSet_runs_with_userDefaults_backing() {
    let key = "GraphStoredWillSetTests.username"
    UserDefaults.standard.removeObject(forKey: key)

    final class Settings {
      @GraphStored(backed: .userDefaults(key: "GraphStoredWillSetTests.username"))
      var username: String = "anonymous" {
        willSet {
          history.append((username, newValue))
        }
      }

      var history: [(String, String)] = []
    }

    let settings = Settings()

    settings.username = "blob"

    #expect(settings.history.count == 1)
    #expect(settings.history[0].0 == "anonymous")
    #expect(settings.history[0].1 == "blob")

    UserDefaults.standard.removeObject(forKey: key)
  }
}
