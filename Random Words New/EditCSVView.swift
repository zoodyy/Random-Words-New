import SwiftUI

struct EditCSVView: View {
    
    let csvFileName: String
    var scrollToWord: String?
    
    @State private var words: [String] = []
    @State private var originalOrder: [String] = []
    @State private var newWord: String = ""
    
    @State private var sortMode: SortMode = .reverseOriginal
    @State private var showingDeleteConfirmation = false
    
    // ✅ Highlight state
    @State private var highlightedWord: String?
    
    @Environment(\.dismiss) private var dismiss
    
    enum SortMode: String, CaseIterable {
        case original = "CSV Order"
        case reverseOriginal = "Reverse CSV Order"
        case alphabetical = "Alphabetical"
        case reverseAlphabetical = "Reverse Alphabetical"
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            List {
                
                // MARK: - Add New Word
                Section(header: Text("Add New Word")) {
                    HStack {
                        TextField("New word", text: $newWord)
                            .textInputAutocapitalization(.never)
                        
                        Button("Add") {
                            addWord()
                        }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                
                // MARK: - Words
                Section(header: Text("Words")) {
                    ForEach(words.indices, id: \.self) { index in
                        TextField("Word", text: $words[index])
                            .id(words[index])
                            .textInputAutocapitalization(.never)
                            .listRowBackground(
                                highlightedWord == words[index]
                                ? Color.yellow.opacity(0.4)
                                : Color.clear
                            )
                            .animation(.easeInOut(duration: 0.3), value: highlightedWord)
                    }
                    .onDelete(perform: deleteWords)
                }
                
                // MARK: - Delete CSV
                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Text("Delete CSV File")
                    }
                }
            }
            .navigationTitle("\(csvFileName).csv")
            .onAppear {
                ensureFileExistsInDocuments()
                loadCSV()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard let target = scrollToWord,
                          words.contains(target) else { return }
                    
                    // Scroll to word
                    proxy.scrollTo(target, anchor: .center)
                    
                    // Highlight it
                    highlightedWord = target
                    
                    // Remove highlight after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            highlightedWord = nil
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - File Handling
    
    private func ensureFileExistsInDocuments() {
        let docURL = getDocumentsURL()
        
        if !FileManager.default.fileExists(atPath: docURL.path) {
            if let bundlePath = Bundle.main.path(forResource: csvFileName, ofType: "csv") {
                try? FileManager.default.copyItem(atPath: bundlePath, toPath: docURL.path)
            }
        }
    }
    
    private func loadCSV() {
        let fileURL = getDocumentsURL()
        
        if let content = try? String(contentsOf: fileURL) {
            originalOrder = content
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        
        applyCurrentSort()
    }
    
    private func applyCurrentSort() {
        switch sortMode {
        case .original:
            words = originalOrder
            
        case .reverseOriginal:
            words = Array(originalOrder.reversed())
            
        case .alphabetical:
            words = originalOrder.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            
        case .reverseAlphabetical:
            words = originalOrder.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedDescending
            }
        }
    }
    
    private func getDocumentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(csvFileName).csv")
    }
    
    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        originalOrder.append(trimmed)
        newWord = ""
        
        applyCurrentSort()
        
        let fileURL = getDocumentsURL()
        try? originalOrder.joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    private func deleteWords(at offsets: IndexSet) {
        let removedWords = offsets.map { words[$0] }
        
        words.remove(atOffsets: offsets)
        originalOrder.removeAll { removedWords.contains($0) }
        
        let fileURL = getDocumentsURL()
        try? originalOrder.joined(separator: "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
