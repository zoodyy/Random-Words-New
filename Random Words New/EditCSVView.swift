import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let csvDeleted = Notification.Name("csvDeleted")
}

struct EditCSVView: View {
    
    let csvFileName: String
    let scrollToWord: String?
    
    @State private var words: [String] = []
    @State private var originalOrder: [String] = []
    @State private var newWord: String = ""
    @State private var highlightedWord: String?
    
    @State private var sortMode: SortMode = .reverseOriginal
    @State private var showingDeleteConfirmation = false
    
    @State private var isSearching: Bool = false
    @State private var searchText: String = ""
    
    @Environment(\.dismiss) private var dismiss
    
    enum SortMode: String, CaseIterable {
        case original = "CSV Order"
        case reverseOriginal = "Reverse CSV Order"
        case alphabetical = "Alphabetical"
        case reverseAlphabetical = "Reverse Alphabetical"
    }
    
    private var filteredWords: [String] {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            return words
        } else {
            return words.filter {
                $0.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            List {
                
                if isSearching {
                    Section {
                        TextField("Search", text: $searchText)
                            .textInputAutocapitalization(.never)
                    }
                }
                
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
                
                Section {
                    ForEach(filteredWords.indices, id: \.self) { index in
                        let word = filteredWords[index]
                        if let realIndex = words.firstIndex(of: word) {
                            TextField("Word", text: $words[realIndex])
                                .id(realIndex)
                                .onChange(of: words[realIndex]) { _ in
                                    syncToOriginalOrder()
                                }
                                .listRowBackground(
                                    highlightedWord == word
                                    ? Color.gray.opacity(0.5)
                                    : Color.clear
                                )
                        }
                    }
                    .onDelete { offsets in
                        let wordsToDelete = offsets.map { filteredWords[$0] }
                        words.removeAll { wordsToDelete.contains($0) }
                        originalOrder.removeAll { wordsToDelete.contains($0) }
                        saveCSV()
                    }
                }
                
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
                
                ToolbarItemGroup(placement: .topBarTrailing) {
                    
                    ShareLink(
                        item: getDocumentsURL(),
                        preview: SharePreview("\(csvFileName).csv")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .onTapGesture {
                        saveCSV()
                    }
                    
                    Button {
                        isSearching.toggle()
                        if !isSearching {
                            searchText = ""
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .alert("Delete CSV File?",
                   isPresented: $showingDeleteConfirmation) {
                
                Button("Delete", role: .destructive) {
                    deleteCSVFile()
                }
                
                Button("Cancel", role: .cancel) { }
                
            } message: {
                Text("This will permanently delete this CSV file.")
            }
            .onAppear {
                ensureFileExistsInDocuments()
                loadCSV()
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let word = scrollToWord,
                       let index = words.firstIndex(of: word) {
                        highlightedWord = word
                        withAnimation {
                            proxy.scrollTo(index, anchor: .center)
                        }
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            highlightedWord = nil
                        }
                    }
                }
            }
            .onDisappear {
                saveCSV()
            }
        }
    }
    
    private func deleteCSVFile() {
        let fileURL = getDocumentsURL()
        
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            
            NotificationCenter.default.post(
                name: .csvDeleted,
                object: csvFileName
            )
            
            dismiss()
            
        } catch {
            print("Failed to delete CSV: \(error)")
        }
    }
    
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
    
    private func saveCSV() {
        syncToOriginalOrder()
        let fileURL = getDocumentsURL()
        let content = originalOrder.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
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
    
    private func syncToOriginalOrder() {
        switch sortMode {
        case .original:
            originalOrder = words
        case .reverseOriginal:
            originalOrder = Array(words.reversed())
        case .alphabetical, .reverseAlphabetical:
            originalOrder = words
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
        saveCSV()
    }
}
