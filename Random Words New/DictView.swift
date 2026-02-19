import SwiftUI

struct DictView: View {
    
    @Binding var selectedCSVs: Set<String>
    @Binding var words: [String]
    @Binding var csvRanges: [String: (Double, Double)]
    @Binding var sliderChangeTrigger: Int
    
    // ✅ Now dynamic
    @State private var csvFiles: [String] = [
        "ownVocab",
        "333kWordsEnglishByFreq",
        "45kWordsEnglishByFreq",
        "10kTVMovieByFreq",
        "2kFictionByFreq",
        "2kPoetryByFreq"
    ]
    
    @State private var csvToEdit: String?
    @State private var showingAddAlert = false
    @State private var newCSVName = ""
    
    // Keeps selected files at top (preserving order)
    private var orderedCSVFiles: [String] {
        let selected = csvFiles.filter { selectedCSVs.contains($0) }
        let unselected = csvFiles.filter { !selectedCSVs.contains($0) }
        return selected + unselected
    }
    
    var body: some View {
        List {
            ForEach(orderedCSVFiles, id: \.self) { file in
                
                VStack(alignment: .leading, spacing: 8) {
                    
                    // MARK: - Row
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(.blue)
                        
                        Text("\(file).csv")
                        
                        Spacer()
                        
                        if selectedCSVs.contains(file) {
                            Image(systemName: "checkmark")
                                .foregroundColor(.green)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleSelection(file)
                    }
                    
                    // MARK: - Sliders
                    if selectedCSVs.contains(file) {
                        let range = csvRanges[file] ?? (0.0, 1.0)
                        
                        Text("\(Int(range.0*100))% - \(Int(range.1*100))%")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        
                        Slider(value: Binding(
                            get: { csvRanges[file]?.0 ?? 0.0 },
                            set: { newValue in
                                let upper = csvRanges[file]?.1 ?? 1.0
                                csvRanges[file] = (min(newValue, upper), upper)
                                sliderChangeTrigger += 1
                            }
                        ), in: 0...1)
                        
                        Slider(value: Binding(
                            get: { csvRanges[file]?.1 ?? 1.0 },
                            set: { newValue in
                                let lower = csvRanges[file]?.0 ?? 0.0
                                csvRanges[file] = (lower, max(newValue, lower))
                                sliderChangeTrigger += 1
                            }
                        ), in: 0...1)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button {
                        csvToEdit = file
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        }
        .navigationTitle("Select Word Lists")
        .toolbar {
            
            // Add Button
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(item: $csvToEdit) { file in
            EditCSVView(csvFileName: file)
        }
        .alert("New CSV File", isPresented: $showingAddAlert) {
            TextField("File name", text: $newCSVName)
            
            Button("Create") {
                createNewCSV()
            }
            
            Button("Cancel", role: .cancel) { }
            
        } message: {
            Text("Enter a name for your new CSV file.")
        }
        .onAppear {
            loadUserCSVs()
        }
    }
    
    // MARK: - Create New CSV
    
    private func createNewCSV() {
        let trimmed = newCSVName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".csv", with: "")
        
        guard !trimmed.isEmpty else { return }
        guard !csvFiles.contains(trimmed) else { return }
        
        let url = getDocumentsURL(for: trimmed)
        
        // Create empty file
        try? "".write(to: url, atomically: true, encoding: .utf8)
        
        // Insert at top
        csvFiles.insert(trimmed, at: 0)
        
        // Auto select
        selectedCSVs.insert(trimmed)
        csvRanges[trimmed] = (0.0, 1.0)
        
        newCSVName = ""
        sliderChangeTrigger += 1
    }
    
    // MARK: - Load Existing User CSVs
    
    private func loadUserCSVs() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        if let files = try? FileManager.default.contentsOfDirectory(at: documentsURL,
                                                                     includingPropertiesForKeys: nil) {
            
            let csvNames = files
                .filter { $0.pathExtension == "csv" }
                .map { $0.deletingPathExtension().lastPathComponent }
            
            for name in csvNames {
                if !csvFiles.contains(name) {
                    csvFiles.append(name)
                }
            }
        }
    }
    
    private func getDocumentsURL(for name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(name).csv")
    }
    
    // MARK: - Selection
    
    private func toggleSelection(_ file: String) {
        if selectedCSVs.contains(file) {
            selectedCSVs.remove(file)
            csvRanges[file] = nil
        } else {
            selectedCSVs.insert(file)
            if csvRanges[file] == nil {
                csvRanges[file] = (0.0, 1.0)
            }
        }
        sliderChangeTrigger += 1
    }
}
