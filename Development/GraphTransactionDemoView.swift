import StateGraph
import SwiftUI

/// Owns the graph-backed values displayed by ``GraphTransactionDemoView``.
///
/// The semantic mutation methods keep the transaction boundary visible in one
/// place while the view remains responsible only for presentation and actions.
final class GraphTransactionDemoModel: Sendable {

  @GraphStored
  private(set) var firstValue: Int = 0

  @GraphStored
  private(set) var secondValue: Int = 0

  /// Advances both values to the same next value in one graph transaction.
  func advanceTogether() {
    withGraphTransaction {
      let nextValue = max(firstValue, secondValue) + 1
      firstValue = nextValue
      secondValue = nextValue
    }
  }

  /// Advances only the first value so the UI can display an intermediate state.
  func advanceFirst() {
    firstValue += 1
  }

  /// Advances only the second value so the UI can display an intermediate state.
  func advanceSecond() {
    secondValue += 1
  }

  /// Restores both values atomically.
  func reset() {
    withGraphTransaction {
      firstValue = 0
      secondValue = 0
    }
  }
}

/// A pair of values captured during one SwiftUI body evaluation.
private struct GraphTransactionSnapshot: Equatable {

  let firstValue: Int
  let secondValue: Int

  var isSynchronized: Bool {
    firstValue == secondValue
  }
}

/// Demonstrates the SwiftUI snapshot published by ``withGraphTransaction``.
struct GraphTransactionDemoView: View {

  @State private var model: GraphTransactionDemoModel
  @State private var events: [GraphTransactionUpdateEvent]

  init() {
    let model = GraphTransactionDemoModel()
    let initialSnapshot = GraphTransactionSnapshot(
      firstValue: model.firstValue,
      secondValue: model.secondValue
    )

    _model = State(initialValue: model)
    _events = State(
      initialValue: [
        GraphTransactionUpdateEvent(
          id: 1,
          snapshot: initialSnapshot
        )
      ]
    )
  }

  var body: some View {
    let snapshot = GraphTransactionSnapshot(
      firstValue: model.firstValue,
      secondValue: model.secondValue
    )

    Form {
      GraphTransactionExplanationSection()
      GraphTransactionCurrentStateSection(snapshot: snapshot)
      GraphTransactionActionsSection(
        onAdvanceTogether: {
          model.advanceTogether()
        },
        onAdvanceFirst: {
          model.advanceFirst()
        },
        onAdvanceSecond: {
          model.advanceSecond()
        },
        onReset: {
          model.reset()
        }
      )
      GraphTransactionUpdateHistorySection(events: events)
    }
    .navigationTitle("withGraphTransaction")
    .onChange(of: snapshot) { _, newSnapshot in
      let nextID = (events.last?.id ?? 0) + 1
      events.append(
        GraphTransactionUpdateEvent(
          id: nextID,
          snapshot: newSnapshot
        )
      )

      if events.count > GraphTransactionUpdateHistorySection.maximumEventCount {
        events.removeFirst(
          events.count - GraphTransactionUpdateHistorySection.maximumEventCount
        )
      }
    }
  }
}

/// Explains what a successful transaction update looks like in the history.
private struct GraphTransactionExplanationSection: View {

  var body: some View {
    Section {
      Text(
        """
        SwiftUI reads both graph values as one snapshot. A transaction update \
        should add one synchronized row to the history without exposing an \
        intermediate value.
        """
      )
    } header: {
      Text("What to check")
    }
  }
}

/// Displays the pair of graph values read by the current SwiftUI update.
private struct GraphTransactionCurrentStateSection: View {

  let snapshot: GraphTransactionSnapshot

  var body: some View {
    Section {
      LabeledContent("First value") {
        Text(snapshot.firstValue, format: .number)
          .monospacedDigit()
      }

      LabeledContent("Second value") {
        Text(snapshot.secondValue, format: .number)
          .monospacedDigit()
      }

      HStack {
        Text("Snapshot")

        Spacer()

        if snapshot.isSynchronized {
          Label("Synchronized", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Label("Intermediate", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }
    } header: {
      Text("Current snapshot")
    }
  }
}

/// Exposes transaction and individual mutation paths for comparison.
private struct GraphTransactionActionsSection: View {

  let onAdvanceTogether: @MainActor @Sendable () -> Void
  let onAdvanceFirst: @MainActor @Sendable () -> Void
  let onAdvanceSecond: @MainActor @Sendable () -> Void
  let onReset: @MainActor @Sendable () -> Void

  var body: some View {
    Section {
      Button(action: onAdvanceTogether) {
        Label(
          "Advance both with transaction",
          systemImage: "arrow.triangle.2.circlepath"
        )
      }

      Button(action: onAdvanceFirst) {
        Label("Advance first only", systemImage: "1.circle")
      }

      Button(action: onAdvanceSecond) {
        Label("Advance second only", systemImage: "2.circle")
      }

      Button(action: onReset) {
        Label("Reset with transaction", systemImage: "arrow.counterclockwise")
      }
    } header: {
      Text("Actions")
    } footer: {
      Text(
        """
        Individual updates intentionally create a visible intermediate row. \
        The transaction action synchronizes both values in one published update.
        """
      )
    }
  }
}

/// One persisted entry in the SwiftUI update history.
private struct GraphTransactionUpdateEvent: Identifiable {

  let id: Int
  let snapshot: GraphTransactionSnapshot
}

/// Records the latest snapshots delivered to this child view by SwiftUI.
private struct GraphTransactionUpdateHistorySection: View {

  static let maximumEventCount = 12

  let events: [GraphTransactionUpdateEvent]

  var body: some View {
    Section {
      ForEach(events.reversed()) { event in
        GraphTransactionUpdateHistoryRow(event: event)
      }
    } header: {
      Text("Observed SwiftUI updates")
    } footer: {
      Text("Showing the 12 most recent snapshots, including the initial value.")
    }
  }
}

/// Renders one snapshot with an explicit synchronized/intermediate indicator.
private struct GraphTransactionUpdateHistoryRow: View {

  let event: GraphTransactionUpdateEvent

  var body: some View {
    HStack {
      if event.snapshot.isSynchronized {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
          .accessibilityLabel("Synchronized snapshot")
      } else {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .accessibilityLabel("Intermediate snapshot")
      }

      Text("Update \(event.id)")

      Spacer()

      Text(
        "\(event.snapshot.firstValue), \(event.snapshot.secondValue)",
        comment: "The first and second graph values captured by one SwiftUI update."
      )
      .monospacedDigit()
      .foregroundStyle(.secondary)
    }
  }
}

#Preview("Graph transaction") {
  NavigationStack {
    GraphTransactionDemoView()
  }
}
