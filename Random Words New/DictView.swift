import SwiftUI

struct DictView: View {
    
    @Binding var selectedCSVs: Set<String>                  // selected CSV files
    @Binding var words: [String]                             // combined words (not strictly needed here)
    @Binding var csvRanges: [String: (Double, Double)]       // slider per CSV
    @Binding var sliderChangeTrigger: Int                    // trigger to notify ContentView
    
    // Word lists source: https://en.wiktionary.org/wiki/Wiktionary:Frequency_lists/English
    private let csvFiles = ["ownVocab",
                            "333kWordsEnglishByFreq",
                            "45kWordsEnglishByFreq",
                            "10kTVMovieByFreq",
                            "2kFictionByFreq",
                            "2kPoetryByFreq"]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                
                // MARK: - CSV Selection List
                ForEach(csvFiles, id: \.self) { file in
                    VStack(spacing: 5) {
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
                        .background(selectedCSVs.contains(file) ? Color.green.opacity(0.2) : Color.clear)
                        .onTapGesture { toggleSelection(file) }
                        
                        // MARK: - Sliders for selected CSV
                        if selectedCSVs.contains(file) {
                            VStack(spacing: 5) {
                                let range = csvRanges[file] ?? (0.0, 1.0)
                                
                                Text("\(Int(range.0*100))% - \(Int(range.1*100))%")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                
                                // Lower bound slider
                                Slider(value: Binding(
                                    get: { csvRanges[file]?.0 ?? 0.0 },
                                    set: { newValue in
                                        let upper = csvRanges[file]?.1 ?? 1.0
                                        csvRanges[file] = (min(newValue, upper), upper)
                                        sliderChangeTrigger += 1
                                    }
                                ), in: 0...1)
                                
                                // Upper bound slider
                                Slider(value: Binding(
                                    get: { csvRanges[file]?.1 ?? 1.0 },
                                    set: { newValue in
                                        let lower = csvRanges[file]?.0 ?? 0.0
                                        csvRanges[file] = (lower, max(newValue, lower))
                                        sliderChangeTrigger += 1
                                    }
                                ), in: 0...1)
                            }
                            .padding(.horizontal)
                        }
                    }
                    Divider()
                }
            }
            .padding()
        }
        .navigationTitle("Select Word Lists")
    }
    
    // MARK: - Toggle CSV Selection
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

#Preview {
    DictView(
        selectedCSVs: .constant(["example"]),
        words: .constant([]),
        csvRanges: .constant(["example": (0.0, 1.0)]),
        sliderChangeTrigger: .constant(0)
    )
}
