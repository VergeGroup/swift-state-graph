# UIKit Integration

Reactive programming with Swift State Graph in UIKit applications.

## Overview

While Swift State Graph doesn't have direct UIKit-specific APIs, its reactive nature makes it easy to integrate with UIKit through the `withGraphTracking` function. This enables you to build reactive UIKit applications that automatically update when your state changes.

## Basic Integration Pattern

The fundamental pattern for UIKit integration uses `withGraphTracking` to observe state changes and update UI components:

```swift
import UIKit
import StateGraph

final class CounterViewModel {
  @GraphStored
  var count: Int = 0

  @GraphComputed
  var isEven: Bool

  @GraphComputed
  var displayText: String

  init() {
    self.$isEven = .init { [$count] _ in
      $count.wrappedValue % 2 == 0
    }
    
    self.$displayText = .init { [$count, $isEven] _ in
      let number = $count.wrappedValue
      let parity = $isEven.wrappedValue ? "even" : "odd"
      return "Count: \(number) (\(parity))"
    }
  }

  func increment() { count += 1 }
  func decrement() { count -= 1 }
}

class CounterViewController: UIViewController {
  private let viewModel = CounterViewModel()
  private var subscription: AnyCancellable?

  @IBOutlet private weak var countLabel: UILabel!
  @IBOutlet private weak var statusLabel: UILabel!
  @IBOutlet private weak var incrementButton: UIButton!
  @IBOutlet private weak var decrementButton: UIButton!

  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    bindViewModel()
  }

  private func setupUI() {
    incrementButton.addTarget(self, action: #selector(incrementTapped), for: .touchUpInside)
    decrementButton.addTarget(self, action: #selector(decrementTapped), for: .touchUpInside)
  }

  private func bindViewModel() {
    // Initial update
    updateUI()

    // Reactive updates
    subscription = withGraphTracking {
      viewModel.$displayText.onChange { [weak self] text in
        self?.countLabel.text = text
      }
      
      viewModel.$isEven.onChange { [weak self] isEven in
        self?.statusLabel.text = isEven ? "Even Number" : "Odd Number"
        self?.statusLabel.textColor = isEven ? .systemBlue : .systemOrange
      }
    }
  }

  private func updateUI() {
    countLabel.text = viewModel.displayText
    statusLabel.text = viewModel.isEven ? "Even Number" : "Odd Number"
    statusLabel.textColor = viewModel.isEven ? .systemBlue : .systemOrange
  }

  @objc private func incrementTapped() {
    viewModel.increment()
  }

  @objc private func decrementTapped() {
    viewModel.decrement()
  }
}
```

## Table View Integration

Swift State Graph works well with `UITableView` for managing dynamic lists:

```swift
final class TodoListViewModel {
  @GraphStored
  var todos: [Todo] = []

  @GraphStored
  var filter: TodoFilter = .all

  @GraphComputed
  var filteredTodos: [Todo]

  @GraphComputed
  var completedCount: Int

  @GraphComputed
  var remainingCount: Int

  init() {
    self.$filteredTodos = .init { [$todos, $filter] _ in
      let todos = $todos.wrappedValue
      switch $filter.wrappedValue {
      case .all: return todos
      case .active: return todos.filter { !$0.isCompleted }
      case .completed: return todos.filter { $0.isCompleted }
      }
    }

    self.$completedCount = .init { [$todos] _ in
      $todos.wrappedValue.count { $0.isCompleted }
    }

    self.$remainingCount = .init { [$todos] _ in
      $todos.wrappedValue.count { !$0.isCompleted }
    }
  }

  func addTodo(_ title: String) {
    let todo = Todo(title: title)
    todos.append(todo)
  }

  func toggleTodo(at index: Int) {
    guard filteredTodos.indices.contains(index) else { return }
    let todo = filteredTodos[index]
    
    if let originalIndex = todos.firstIndex(where: { $0.id == todo.id }) {
      todos[originalIndex].isCompleted.toggle()
    }
  }
  
  func deleteTodo(at index: Int) {
    guard filteredTodos.indices.contains(index) else { return }
    let todo = filteredTodos[index]
    todos.removeAll { $0.id == todo.id }
  }
}

class TodoListViewController: UIViewController {
  private let viewModel = TodoListViewModel()
  private var subscription: AnyCancellable?

  @IBOutlet private weak var tableView: UITableView!
  @IBOutlet private weak var filterSegmentedControl: UISegmentedControl!
  @IBOutlet private weak var statusLabel: UILabel!

  override func viewDidLoad() {
    super.viewDidLoad()
    setupTableView()
    setupFilterControl()
    bindViewModel()
  }

  private func setupTableView() {
    tableView.delegate = self
    tableView.dataSource = self
    tableView.register(TodoCell.self, forCellReuseIdentifier: "TodoCell")
  }
  
  private func setupFilterControl() {
    filterSegmentedControl.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
  }

  private func bindViewModel() {
    // Initial update
    updateUI()

    subscription = withGraphTracking {
      viewModel.$filteredTodos.onChange { [weak self] _ in
        DispatchQueue.main.async {
          self?.tableView.reloadData()
        }
      }

      viewModel.$completedCount.onChange { [weak self] _ in
        self?.updateStatusLabel()
      }

      viewModel.$remainingCount.onChange { [weak self] _ in
        self?.updateStatusLabel()
      }
    }
  }

  private func updateUI() {
    tableView.reloadData()
    updateStatusLabel()
  }

  private func updateStatusLabel() {
    let total = viewModel.todos.count
    let completed = viewModel.completedCount
    let remaining = viewModel.remainingCount
    
    statusLabel.text = "Total: \(total) • Completed: \(completed) • Remaining: \(remaining)"
  }

  @objc private func filterChanged() {
    let filters: [TodoFilter] = [.all, .active, .completed]
    viewModel.filter = filters[filterSegmentedControl.selectedSegmentIndex]
  }
}

// MARK: - UITableViewDataSource
extension TodoListViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return viewModel.filteredTodos.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "TodoCell", for: indexPath) as! TodoCell
    let todo = viewModel.filteredTodos[indexPath.row]
    cell.configure(with: todo)
    return cell
  }
}

// MARK: - UITableViewDelegate
extension TodoListViewController: UITableViewDelegate {
  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    viewModel.toggleTodo(at: indexPath.row)
  }
  
  func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
    if editingStyle == .delete {
      viewModel.deleteTodo(at: indexPath.row)
    }
  }
}
```

## Collection View Integration

Similar patterns work with `UICollectionView`:

```swift
final class PhotoGalleryViewModel {
  @GraphStored
  var photos: [Photo] = []

  @GraphStored
  var selectedCategory: PhotoCategory = .all

  @GraphComputed
  var filteredPhotos: [Photo]

  @GraphComputed
  var categoryCount: Int

  init() {
    self.$filteredPhotos = .init { [$photos, $selectedCategory] _ in
      let photos = $photos.wrappedValue
      let category = $selectedCategory.wrappedValue
      
      if category == .all {
        return photos
      } else {
        return photos.filter { $0.category == category }
      }
    }

    self.$categoryCount = .init { [$filteredPhotos] _ in
      $filteredPhotos.wrappedValue.count
    }
  }
}

class PhotoGalleryViewController: UIViewController {
  private let viewModel = PhotoGalleryViewModel()
  private var subscription: AnyCancellable?

  @IBOutlet private weak var collectionView: UICollectionView!

  override func viewDidLoad() {
    super.viewDidLoad()
    setupCollectionView()
    bindViewModel()
  }

  private func setupCollectionView() {
    collectionView.dataSource = self
    collectionView.delegate = self
    collectionView.register(PhotoCell.self, forCellWithReuseIdentifier: "PhotoCell")
  }

  private func bindViewModel() {
    subscription = withGraphTracking {
      viewModel.$filteredPhotos.onChange { [weak self] _ in
        DispatchQueue.main.async {
          self?.collectionView.reloadData()
        }
      }
    }
  }
}

extension PhotoGalleryViewController: UICollectionViewDataSource {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    return viewModel.filteredPhotos.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "PhotoCell", for: indexPath) as! PhotoCell
    let photo = viewModel.filteredPhotos[indexPath.item]
    cell.configure(with: photo)
    return cell
  }
}
```

## Navigation and Coordinator Pattern

Swift State Graph works well with coordinator patterns for navigation:

```swift
final class AppCoordinator {
  @GraphStored
  var currentScreen: Screen = .home

  @GraphStored
  var navigationStack: [Screen] = []

  private let navigationController: UINavigationController
  private var subscription: AnyCancellable?

  init(navigationController: UINavigationController) {
    self.navigationController = navigationController
    setupNavigation()
  }

  private func setupNavigation() {
    subscription = withGraphTracking {
      self.$currentScreen.onChange { [weak self] screen in
        self?.navigate(to: screen)
      }
    }
  }

  private func navigate(to screen: Screen) {
    let viewController = createViewController(for: screen)
    navigationController.pushViewController(viewController, animated: true)
  }

  private func createViewController(for screen: Screen) -> UIViewController {
    switch screen {
    case .home:
      return HomeViewController(coordinator: self)
    case .profile:
      return ProfileViewController(coordinator: self)
    case .settings:
      return SettingsViewController(coordinator: self)
    }
  }

  func showProfile() {
    currentScreen = .profile
  }

  func showSettings() {
    currentScreen = .settings
  }
}

enum Screen {
  case home
  case profile
  case settings
}
```

## Form Handling

Create reactive forms with validation:

```swift
final class RegistrationFormViewModel {
  @GraphStored var firstName: String = ""
  @GraphStored var lastName: String = ""
  @GraphStored var email: String = ""
  @GraphStored var password: String = ""
  @GraphStored var confirmPassword: String = ""

  @GraphComputed var isFirstNameValid: Bool
  @GraphComputed var isLastNameValid: Bool
  @GraphComputed var isEmailValid: Bool
  @GraphComputed var isPasswordValid: Bool
  @GraphComputed var isConfirmPasswordValid: Bool
  @GraphComputed var isFormValid: Bool

  init() {
    self.$isFirstNameValid = .init { [$firstName] _ in
      !$firstName.wrappedValue.isEmpty
    }

    self.$isLastNameValid = .init { [$lastName] _ in
      !$lastName.wrappedValue.isEmpty
    }

    self.$isEmailValid = .init { [$email] _ in
      $email.wrappedValue.contains("@") && $email.wrappedValue.contains(".")
    }

    self.$isPasswordValid = .init { [$password] _ in
      $password.wrappedValue.count >= 8
    }

    self.$isConfirmPasswordValid = .init { [$password, $confirmPassword] _ in
      $password.wrappedValue == $confirmPassword.wrappedValue
    }

    self.$isFormValid = .init { 
      [$isFirstNameValid, $isLastNameValid, $isEmailValid, $isPasswordValid, $isConfirmPasswordValid] _ in
      $isFirstNameValid.wrappedValue &&
      $isLastNameValid.wrappedValue &&
      $isEmailValid.wrappedValue &&
      $isPasswordValid.wrappedValue &&
      $isConfirmPasswordValid.wrappedValue
    }
  }
}

class RegistrationViewController: UIViewController {
  private let viewModel = RegistrationFormViewModel()
  private var subscription: AnyCancellable?

  @IBOutlet private weak var firstNameTextField: UITextField!
  @IBOutlet private weak var lastNameTextField: UITextField!
  @IBOutlet private weak var emailTextField: UITextField!
  @IBOutlet private weak var passwordTextField: UITextField!
  @IBOutlet private weak var confirmPasswordTextField: UITextField!
  @IBOutlet private weak var submitButton: UIButton!

  override func viewDidLoad() {
    super.viewDidLoad()
    setupTextFields()
    bindViewModel()
  }

  private func setupTextFields() {
    firstNameTextField.addTarget(self, action: #selector(firstNameChanged), for: .editingChanged)
    lastNameTextField.addTarget(self, action: #selector(lastNameChanged), for: .editingChanged)
    emailTextField.addTarget(self, action: #selector(emailChanged), for: .editingChanged)
    passwordTextField.addTarget(self, action: #selector(passwordChanged), for: .editingChanged)
    confirmPasswordTextField.addTarget(self, action: #selector(confirmPasswordChanged), for: .editingChanged)
    
    submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
  }

  private func bindViewModel() {
    subscription = withGraphTracking {
      viewModel.$isFirstNameValid.onChange { [weak self] isValid in
        self?.updateFieldValidation(textField: self?.firstNameTextField, isValid: isValid)
      }

      viewModel.$isLastNameValid.onChange { [weak self] isValid in
        self?.updateFieldValidation(textField: self?.lastNameTextField, isValid: isValid)
      }

      viewModel.$isEmailValid.onChange { [weak self] isValid in
        self?.updateFieldValidation(textField: self?.emailTextField, isValid: isValid)
      }

      viewModel.$isPasswordValid.onChange { [weak self] isValid in
        self?.updateFieldValidation(textField: self?.passwordTextField, isValid: isValid)
      }

      viewModel.$isConfirmPasswordValid.onChange { [weak self] isValid in
        self?.updateFieldValidation(textField: self?.confirmPasswordTextField, isValid: isValid)
      }

      viewModel.$isFormValid.onChange { [weak self] isValid in
        self?.submitButton.isEnabled = isValid
        self?.submitButton.alpha = isValid ? 1.0 : 0.5
      }
    }
  }

  private func updateFieldValidation(textField: UITextField?, isValid: Bool) {
    textField?.layer.borderColor = isValid ? UIColor.systemGreen.cgColor : UIColor.systemRed.cgColor
    textField?.layer.borderWidth = isValid ? 1.0 : 2.0
  }

  @objc private func firstNameChanged() {
    viewModel.firstName = firstNameTextField.text ?? ""
  }

  @objc private func lastNameChanged() {
    viewModel.lastName = lastNameTextField.text ?? ""
  }

  @objc private func emailChanged() {
    viewModel.email = emailTextField.text ?? ""
  }

  @objc private func passwordChanged() {
    viewModel.password = passwordTextField.text ?? ""
  }

  @objc private func confirmPasswordChanged() {
    viewModel.confirmPassword = confirmPasswordTextField.text ?? ""
  }

  @objc private func submitTapped() {
    // Handle form submission
    print("Form submitted!")
  }
}
```

## Loading States and Error Handling

Manage loading states and errors reactively:

```swift
final class DataViewModel {
  @GraphStored var isLoading: Bool = false
  @GraphStored var data: [Item]? = nil
  @GraphStored var error: Error? = nil

  @GraphComputed var viewState: ViewState

  init() {
    self.$viewState = .init { [$isLoading, $data, $error] _ in
      if $isLoading.wrappedValue {
        return .loading
      } else if let error = $error.wrappedValue {
        return .error(error)
      } else if let data = $data.wrappedValue {
        return .loaded(data)
      } else {
        return .empty
      }
    }
  }

  func loadData() {
    isLoading = true
    error = nil
    
    // Simulate API call
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      self.isLoading = false
      self.data = [Item(name: "Item 1"), Item(name: "Item 2")]
    }
  }
}

enum ViewState {
  case loading
  case loaded([Item])
  case error(Error)
  case empty
}

class DataViewController: UIViewController {
  private let viewModel = DataViewModel()
  private var subscription: AnyCancellable?

  @IBOutlet private weak var loadingView: UIActivityIndicatorView!
  @IBOutlet private weak var tableView: UITableView!
  @IBOutlet private weak var errorLabel: UILabel!
  @IBOutlet private weak var retryButton: UIButton!

  override func viewDidLoad() {
    super.viewDidLoad()
    setupUI()
    bindViewModel()
    viewModel.loadData()
  }

  private func setupUI() {
    retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
    tableView.dataSource = self
  }

  private func bindViewModel() {
    subscription = withGraphTracking {
      viewModel.$viewState.onChange { [weak self] state in
        DispatchQueue.main.async {
          self?.updateUI(for: state)
        }
      }
    }
  }

  private func updateUI(for state: ViewState) {
    loadingView.stopAnimating()
    tableView.isHidden = true
    errorLabel.isHidden = true
    retryButton.isHidden = true

    switch state {
    case .loading:
      loadingView.startAnimating()
      
    case .loaded(let items):
      tableView.isHidden = false
      tableView.reloadData()
      
    case .error(let error):
      errorLabel.isHidden = false
      retryButton.isHidden = false
      errorLabel.text = error.localizedDescription
      
    case .empty:
      errorLabel.isHidden = false
      errorLabel.text = "No data available"
    }
  }

  @objc private func retryTapped() {
    viewModel.loadData()
  }
}

extension DataViewController: UITableViewDataSource {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if case .loaded(let items) = viewModel.viewState {
      return items.count
    }
    return 0
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
    
    if case .loaded(let items) = viewModel.viewState {
      cell.textLabel?.text = items[indexPath.row].name
    }
    
    return cell
  }
}
```

## Memory Management

Proper memory management with subscriptions:

```swift
class BaseViewController: UIViewController {
  private var subscriptions: Set<AnyCancellable> = []
  
  func addSubscription(_ subscription: AnyCancellable) {
    subscription.store(in: &subscriptions)
  }
  
  deinit {
    subscriptions.removeAll()
  }
}

class MyViewController: BaseViewController {
  private let viewModel = MyViewModel()
  
  override func viewDidLoad() {
    super.viewDidLoad()
    bindViewModel()
  }
  
  private func bindViewModel() {
    let subscription = withGraphTracking {
      viewModel.$property.onChange { value in
        // Handle change
      }
    }
    
    addSubscription(subscription)
  }
}
```

## Best Practices

### 1. Use Weak References

Always use weak references in change handlers to prevent retain cycles:

```swift
viewModel.$property.onChange { [weak self] value in
  self?.updateUI(value)
}
```

### 2. Main Thread Updates

Ensure UI updates happen on the main thread:

```swift
viewModel.$property.onChange { [weak self] value in
  DispatchQueue.main.async {
    self?.updateUI(value)
  }
}
```

### 3. Batch UI Updates

Group related UI updates together for better performance:

```swift
private func updateUI() {
  CATransaction.begin()
  
  label.text = viewModel.text
  button.isEnabled = viewModel.isEnabled
  imageView.isHidden = !viewModel.showImage
  
  CATransaction.commit()
}
```

### 4. Subscription Management

Store subscriptions properly to ensure they remain active:

```swift
class ViewController: UIViewController {
  private var subscription: AnyCancellable?
  
  override func viewDidLoad() {
    super.viewDidLoad()
    
    subscription = withGraphTracking {
      // Your tracking code
    }
  }
}
```

Swift State Graph provides a clean, reactive approach to UIKit development, enabling you to build responsive applications with automatic state synchronization and minimal boilerplate code. 