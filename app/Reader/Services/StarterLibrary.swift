import Foundation

enum StarterLibrary {
    struct Book: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        let author: String
    }

    static let books: [Book] = [
        Book(id: "yamanashi", title: "やまなし", author: "宮沢賢治"),
        Book(id: "kumo-no-ito", title: "蜘蛛の糸", author: "芥川竜之介"),
        Book(id: "gon-gitsune", title: "ごん狐", author: "新美南吉"),
        Book(id: "chumon-no-oi-ryoriten", title: "注文の多い料理店", author: "宮沢賢治"),
        Book(id: "rashomon", title: "羅生門", author: "芥川竜之介"),
        Book(id: "lemon", title: "檸檬", author: "梶井基次郎"),
        Book(id: "sangetsuki", title: "山月記", author: "中島敦"),
        Book(id: "yume-juya", title: "夢十夜", author: "夏目漱石"),
    ]

    static func url(for book: Book) -> URL? {
        Bundle.main.url(forResource: book.id, withExtension: "epub")
    }
}
