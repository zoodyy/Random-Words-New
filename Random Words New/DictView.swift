import SwiftUI
import UniformTypeIdentifiers

struct DictView: View {
    
    @Binding var selectedCSVs: Set<String>
    @Binding var words: [String]
    @Binding var csvRanges: [String: (Double, Double)]
    @Binding var sliderChangeTrigger: Int
    
    @State private var csvFiles: [String] = [
        "ownVocab",
        "333kEnglishByFreq",
        "45kEnglishByFreq",
        "10kTVMovieByFreq",
        "2kFictionByFreq",
        "2kPoetryByFreq"
    ]
    
    @State private var csvToEdit: String?
    
    // Create New
    @State private var showingNewCSVAlert = false
    @State private var newCSVName = ""
    
    // Import
    @State private var showingImportPicker = false
    
    // Add menu
    @State private var showingAddOptions = false
    
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
                        
                        Text("\(file)")
                        
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
                        let wordsForFile = loadWords(for: file)
                        
                        let lowerIndex = wordsForFile.isEmpty ? 0 :
                            min(Int(Double(wordsForFile.count - 1) * range.0), wordsForFile.count - 1)
                        
                        let upperIndex = wordsForFile.isEmpty ? 0 :
                            min(Int(Double(wordsForFile.count - 1) * range.1), wordsForFile.count - 1)
                        
                        let lowerWord = wordsForFile.indices.contains(lowerIndex) ? wordsForFile[lowerIndex] : "-"
                        let upperWord = wordsForFile.indices.contains(upperIndex) ? wordsForFile[upperIndex] : "-"
                        
                        Text("\(Int(range.0*100))% (\(lowerWord))  -  \(Int(range.1*100))% (\(upperWord))")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        
                        RangeSlider(
                            lowerValue: Binding(
                                get: { csvRanges[file]?.0 ?? 0.0 },
                                set: { newValue in
                                    let upper = csvRanges[file]?.1 ?? 1.0
                                    csvRanges[file] = (min(newValue, upper), upper)
                                    sliderChangeTrigger += 1
                                }
                            ),
                            upperValue: Binding(
                                get: { csvRanges[file]?.1 ?? 1.0 },
                                set: { newValue in
                                    let lower = csvRanges[file]?.0 ?? 0.0
                                    csvRanges[file] = (lower, max(newValue, lower))
                                    sliderChangeTrigger += 1
                                }
                            )
                        )
                        .frame(height: 32)
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingAddOptions = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(item: $csvToEdit) { file in
            EditCSVView(csvFileName: file, scrollToWord: nil)
        }
        .confirmationDialog("Add CSV", isPresented: $showingAddOptions) {
            
            Button("Create New CSV") {
                showingNewCSVAlert = true
            }
            
            Button("Import CSV from Files") {
                showingImportPicker = true
            }
            
            Button("Cancel", role: .cancel) { }
        }
        .alert("New CSV File", isPresented: $showingNewCSVAlert) {
            TextField("File name", text: $newCSVName)
            
            Button("Create") {
                createNewCSV()
            }
            
            Button("Cancel", role: .cancel) { }
            
        } message: {
            Text("Enter a name for your new CSV file.")
        }
        .fileImporter(
            isPresented: $showingImportPicker,
            allowedContentTypes: [UTType.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result: result)
        }
        .onAppear {
            loadUserCSVs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .csvDeleted)) { notification in
            if let deletedName = notification.object as? String {
                csvFiles.removeAll { $0 == deletedName }
                selectedCSVs.remove(deletedName)
                csvRanges[deletedName] = nil
                sliderChangeTrigger += 1
            }
        }
    }
    
    // MARK: - Load Words For Boundary Display
    
    private func loadWords(for file: String) -> [String] {
        let url = getDocumentsURL(for: file)
        
        if let content = try? String(contentsOf: url) {
            return content
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        
        return []
    }
    
    // MARK: - Create New CSV
    
    private func createNewCSV() {
        let trimmed = newCSVName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".csv", with: "")
        
        guard !trimmed.isEmpty else { return }
        guard !csvFiles.contains(trimmed) else { return }
        
        let url = getDocumentsURL(for: trimmed)
        
        try? "".write(to: url, atomically: true, encoding: .utf8)
        
        csvFiles.insert(trimmed, at: 0)
        selectedCSVs.insert(trimmed)
        csvRanges[trimmed] = (0.0, 1.0)
        
        newCSVName = ""
        sliderChangeTrigger += 1
    }
    
    // MARK: - Import CSV
    
    private func handleImport(result: Result<[URL], Error>) {
        do {
            guard let selectedFile = try result.get().first else { return }
            
            let accessing = selectedFile.startAccessingSecurityScopedResource()
            defer {
                if accessing {
                    selectedFile.stopAccessingSecurityScopedResource()
                }
            }
            
            let fileName = selectedFile
                .deletingPathExtension()
                .lastPathComponent
            
            let cleanedName = fileName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ".csv", with: "")
            
            guard !cleanedName.isEmpty else { return }
            
            let destinationURL = getDocumentsURL(for: cleanedName)
            
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            
            try FileManager.default.copyItem(at: selectedFile, to: destinationURL)
            
            if !csvFiles.contains(cleanedName) {
                csvFiles.insert(cleanedName, at: 0)
            }
            
            selectedCSVs.insert(cleanedName)
            csvRanges[cleanedName] = (0.0, 1.0)
            sliderChangeTrigger += 1
            
        } catch {
            print("Import failed: \(error)")
        }
    }
    
    // MARK: - Load Existing User CSVs
    
    private func loadUserCSVs() {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        if let files = try? FileManager.default.contentsOfDirectory(at: documentsURL,
                                                                     includingPropertiesForKeys: nil) {
            
            let csvNames = files
                .filter { $0.pathExtension.lowercased() == "csv" }
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

private struct RangeSlider: View {
    
    @Binding var lowerValue: Double
    @Binding var upperValue: Double
    
    private let thumbSize: CGFloat = 20
    private let trackHeight: CGFloat = 4
    
    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(geometry.size.width - thumbSize, 1)
            let trackY = (geometry.size.height - trackHeight) / 2
            let thumbY = (geometry.size.height - thumbSize) / 2
            
            let lowerThumbX = CGFloat(lowerValue) * availableWidth
            let upperThumbX = CGFloat(upperValue) * availableWidth
            
            let lowerCenterX = lowerThumbX + thumbSize / 2
            let upperCenterX = upperThumbX + thumbSize / 2
            
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color(.systemGray4))
                    .frame(width: availableWidth, height: trackHeight)
                    .offset(x: thumbSize / 2, y: trackY)
                
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(upperCenterX - lowerCenterX, 0), height: trackHeight)
                    .offset(x: lowerCenterX, y: trackY)
                
                Circle()
                    .fill(Color.white)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor, lineWidth: 2)
                    )
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: lowerThumbX, y: thumbY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newX = min(max(0, value.location.x - thumbSize / 2), upperThumbX)
                                let newValue = Double(newX / availableWidth)
                                lowerValue = newValue
                            }
                    )
                
                Circle()
                    .fill(Color.white)
                    .overlay(
                        Circle()
                            .stroke(Color.accentColor, lineWidth: 2)
                    )
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: upperThumbX, y: thumbY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let newX = max(min(availableWidth, value.location.x - thumbSize / 2), lowerThumbX)
                                let newValue = Double(newX / availableWidth)
                                upperValue = newValue
                            }
                    )
            }
        }
    }
}
