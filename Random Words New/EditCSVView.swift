import SwiftUI

struct EditCSVView: View {
    
    let csvFileName: String
    
    @State private var words: [String] = []
    @State private var newWord: String = ""
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            
            // MARK: - Existing Words
            Section(header: Text("Words")) {
                ForEach(words.indices, id: \.self) { index in
                    TextField("Word", text: $words[index])
                        .textInputAutocapitalization(.never)
                }
                .onDelete(perform: deleteWords)
            }
            
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
        }
        .navigationTitle("\(csvFileName).csv")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    saveCSV()
                    dismiss()
                }
            }
        }
        .onAppear {
            loadCSV()
        }
    }
    
    // MARK: - Load CSV
    
    private func loadCSV() {
        let fileURL = getDocumentsURL()
        
        if FileManager.default.fileExists(atPath: fileURL.path),
           let content = try? String(contentsOf: fileURL) {
            
            words = content
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            
        } else if let bundlePath = Bundle.main.path(forResource: csvFileName, ofType: "csv"),
                  let content = try? String(contentsOfFile: bundlePath) {
            
            words = content
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }
    
    // MARK: - Save CSV
    
    private func saveCSV() {
        let fileURL = getDocumentsURL()
        let content = words.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    // MARK: - Helpers
    
    private func getDocumentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(csvFileName).csv")
    }
    
    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        
        words.append(trimmed)
        newWord = ""
    }
    
    private func deleteWords(at offsets: IndexSet) {
        words.remove(atOffsets: offsets)
    }
}
