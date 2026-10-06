import SwiftUI

/// The word lists a left swipe on the random word screen saves words to.
///
/// Kept in UserDefaults as a set of list names. ownVocab is the favourite
/// until the user changes them, and can be unfavourited like any other list.
enum FavouriteWordlists {

    static let storageKey = "favouriteCSVsData"
    static let defaults: Set<String> = ["ownVocab"]

    static func decode(_ data: Data) -> Set<String> {
        // Nothing stored yet means the favourites have never been changed.
        guard !data.isEmpty else { return defaults }
        return (try? JSONDecoder().decode(Set<String>.self, from: data)) ?? defaults
    }

    static func encode(_ favourites: Set<String>) -> Data {
        (try? JSONEncoder().encode(favourites)) ?? Data()
    }
}

/// The words being saved after a left swipe with several favourite lists,
/// and which of them each list already has.
struct FavouritePickerTarget: Identifiable {
    let id = UUID()
    let words: [String]
    let lists: [String]
    let containedWords: [String: Set<String>]
}

/// Lets the user put the words into any of their favourite lists, or take
/// them back out of one that already has them.
struct FavouriteListPicker: View {

    let words: [String]
    let lists: [String]
    /// Called after each tap with the list and whether the words went in
    /// (`true`) or came out (`false`).
    let onChange: (String, Bool) -> Void

    @State private var containedWords: [String: Set<String>]

    @Environment(\.dismiss) private var dismiss

    init(target: FavouritePickerTarget, onChange: @escaping (String, Bool) -> Void) {
        words = target.words
        lists = target.lists
        self.onChange = onChange
        _containedWords = State(initialValue: target.containedWords)
    }

    private var wordSet: Set<String> {
        Set(words)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lists, id: \.self) { list in
                        Button {
                            toggle(list)
                        } label: {
                            row(for: list)
                        }
                    }
                } header: {
                    Text(words.joined(separator: ", "))
                        .textCase(nil)
                        .lineLimit(3)
                }
            }
            .navigationTitle("Favourite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(for list: String) -> some View {
        let containedCount = containedWords[list]?.count ?? 0

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(list)
                    .foregroundColor(.primary)

                // Only possible with several words on screen at once.
                if containedCount > 0, containedCount < wordSet.count {
                    Text("Has \(containedCount) of \(wordSet.count) words")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if containsAllWords(list) {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func containsAllWords(_ list: String) -> Bool {
        containedWords[list]?.count == wordSet.count
    }

    /// A list with a checkmark gives the words up; any other gets the ones
    /// it's missing.
    private func toggle(_ list: String) {
        if containsAllWords(list) {
            WordlistFile.remove(wordSet, fromListNamed: list)
            containedWords[list] = []
            onChange(list, false)
        } else {
            WordlistFile.add(words, toListNamed: list)
            containedWords[list] = wordSet
            onChange(list, true)
        }
    }
}
