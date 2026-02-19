import SwiftUI

struct EditCSVView: View {
    
    let csvFileName: String
    
    @State private var words: [String] = []
    @State private var originalOrder: [String] = []
    @State private var newWord: String = ""
    
    @State private var sortMode: SortMode = .reverseOriginal
    @State private var showingDeleteConfirmation = false
    
    @Environment(\.dismiss) private var dismiss
    
    enum SortMode: String, CaseIterable {
        case original = "CSV Order"
        case reverseOriginal = "Reverse CSV Order"
        case alphabetical = "Alphabetical"
        case reverseAlphabetical = "Reverse Alphabetical"
    }
    
    var body: some View {
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
            
            // MARK: - Existing Words
            Section() {
                ForEach(words.indices, id: \.self) { index in
                    TextField("Word", text: $words[index])
                        .textInputAutocapitalization(.never)
                }
                .onDelete(perform: deleteWords)
            }
            
            // MARK: - Delete CSV (Bottom Section)
            Section {
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Text("Delete CSV File")
                }
            }
        }
        .navigationTitle("\(csvFileName).csv")
        .toolbar {
            
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        Button {
                            changeSortMode(to: mode)
                        } label: {
                            if sortMode == mode {
                                Label(mode.rawValue, systemImage: "checkmark")
                            } else {
                                Text(mode.rawValue)
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            
            ToolbarItem(placement: .navigationBarTrailing) {
                ShareLink(
                    item: getDocumentsURL(),
                    preview: SharePreview("\(csvFileName).csv")
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    saveCSV()
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "Are you sure you want to delete this CSV?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete CSV", role: .destructive) {
                deleteCSVFile()
            }
            
            Button("Cancel", role: .cancel) { }
        }
        .onAppear {
            ensureFileExistsInDocuments()
            loadCSV()
        }
    }
    
    // MARK: - Delete Entire CSV
    
    private func deleteCSVFile() {
        let url = getDocumentsURL()
        try? FileManager.default.removeItem(at: url)
        dismiss()
    }
    
    // MARK: - Ensure File Exists
    
    private func ensureFileExistsInDocuments() {
        let docURL = getDocumentsURL()
        
        if !FileManager.default.fileExists(atPath: docURL.path) {
            if let bundlePath = Bundle.main.path(forResource: csvFileName, ofType: "csv") {
                try? FileManager.default.copyItem(atPath: bundlePath, toPath: docURL.path)
            }
        }
    }
    
    // MARK: - Load CSV
    
    private func loadCSV() {
        let fileURL = getDocumentsURL()
        
        if let content = try? String(contentsOf: fileURL) {
            originalOrder = content
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        
        applyCurrentSort()
    }
    
    // MARK: - Save CSV
    
    private func saveCSV() {
        let fileURL = getDocumentsURL()
        let content = originalOrder.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Sorting
    
    private func changeSortMode(to mode: SortMode) {
        sortMode = mode
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
    
    // MARK: - Helpers
    
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
        saveCSV()
    }
    
    private func deleteWords(at offsets: IndexSet) {
        let removedWords = offsets.map { words[$0] }
        
        words.remove(atOffsets: offsets)
        originalOrder.removeAll { removedWords.contains($0) }
        
        saveCSV()
    }
}
