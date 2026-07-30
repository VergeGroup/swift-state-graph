import Testing
@testable import StateGraphNormalization

private struct UpdateableArticle {
  let id: Int
  var title: String
  var revision: Int = 0

  @InitAndUpdate
  init(id: Int, title: String, revision: Int) {
    #onInit {
      self.id = id
    }
    self.title = title
    #onUpdate {
      self.revision = revision
    }
  }
}

@Suite
struct InitAndUpdateIntegrationTests {

  @Test func update_keeps_init_only_state_and_updates_the_other_paths() {
    var article = UpdateableArticle(id: 1, title: "First", revision: 10)

    article.update(id: 2, title: "Second", revision: 20)

    #expect(article.id == 1)
    #expect(article.title == "Second")
    #expect(article.revision == 20)
  }
}
