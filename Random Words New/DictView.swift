import SwiftUI

struct DictView: View {
    
    @Binding var selectedCSVs: Set<String>
    @Binding var words: [String]
    @Binding var csvRanges: [String: (Double, Double)]
    @Binding var sliderChangeTrigger: Int
    
    private let csvFiles = ["ownVocab",
                            "333kWordsEnglishByFreq",
                            "45kWordsEnglishByFreq",
                            "10kTVMovieByFreq",
                            "2kFictionByFreq",
                            "2kPoetryByFreq"]
    
    @State private var csvToEdit: String?
    
    var body: some View {
        List {
            ForEach(csvFiles, id: \.self) { file in
                
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
                
                // MARK: - Swipe Action (NOW WORKS)
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
        .navigationDestination(item: $csvToEdit) { file in
            EditCSVView(csvFileName: file)
        }
    }
    
    private func toggleSelection(_ file: String) {
        if selectedCSVs.contains(file) {
            selectedCSVs.remove(file)
            csvRanges[file] = nil
            sliderChangeTrigger += 1
        } else {
            selectedCSVs.insert(file)
            if csvRanges[file] == nil {
                csvRanges[file] = (0.0, 1.0)
            }
            sliderChangeTrigger += 1
        }
    }
}
