import SwiftUI

struct SettingsView: View {
    
    @Binding var switchInterval: Double
    @Binding var numberOfWordsToShow: Int
    @Binding var fairWordDistribution: Bool
    @Binding var selectedThemeRaw: String
    
    var body: some View {
        VStack(spacing: 15) {
            
            Text(switchInterval == 0
                 ? "Manual Mode"
                 : "Switch every \(Int(switchInterval)) sec")
                .font(.headline)
            
            Slider(value: $switchInterval, in: 0...60, step: 1)
                .padding()
            
            Divider()
            
            Text("Words Displayed: \(numberOfWordsToShow)")
                .font(.headline)
            
            Slider(
                value: Binding(
                    get: { Double(numberOfWordsToShow) },
                    set: { numberOfWordsToShow = Int($0) }
                ),
                in: 1...20,
                step: 1
            )
            .padding()
            
            Divider()
            
            Toggle("Fair List Distribution", isOn: $fairWordDistribution)
                .padding(.horizontal)
            
            Divider()
            
            Text("Appearance")
                .font(.headline)
            
            Picker("Theme", selection: $selectedThemeRaw) {
                Text("System").tag("System")
                Text("Light").tag("Light")
                Text("Dark").tag("Dark")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            
            Spacer()
        }
        .padding()
        .navigationTitle("Settings")
    }
}
