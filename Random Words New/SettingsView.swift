import SwiftUI

enum OrientationLock: String, CaseIterable {
    case portrait = "Portrait"
    case landscape = "Landscape"
    case none = "Don't Lock"

    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: return .portrait
        case .landscape: return .landscape
        case .none: return .all
        }
    }

    func apply() {
        AppDelegate.orientationLock = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

struct SettingsView: View {

    @Binding var switchInterval: Double
    @Binding var numberOfWordsToShow: Int
    @Binding var fairWordDistribution: Bool
    @Binding var selectedThemeRaw: String
    @Binding var minimumWordLength: Int
    @Binding var minLengthExcludedCSVs: Set<String>
    @Binding var selectedWordFontRaw: String

    let availableCSVs: [String]

    @AppStorage("orientationLock") private var orientationLockRaw: String = OrientationLock.none.rawValue

    private let availableFonts: [String] = [
        "Default",
        "Slackey",
        "Avenir Next",
        "Georgia",
        "Helvetica Neue",
        "Futura",
        "Chalkboard",
        "Marker Felt",
        "Palatino",
        "Gill Sans",
        "Baskerville",
        "American Typewriter",
        "Copperplate"
    ]

    var body: some View {
        List {
            NavigationLink {
                randomWordsSettings
            } label: {
                Label("Random Word Behaviour", systemImage: "textformat.abc")
            }

            NavigationLink {
                appearancesSettings
            } label: {
                Label("Appearances", systemImage: "paintbrush")
            }
        }
        .navigationTitle("Settings")
    }

    private var randomWordsSettings: some View {
        ScrollView {
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

                Text("Minimum Word Length: \(minimumWordLength)")
                    .font(.headline)

                Slider(
                    value: Binding(
                        get: { Double(minimumWordLength) },
                        set: { minimumWordLength = Int($0) }
                    ),
                    in: 1...30,
                    step: 1
                )
                .padding()

                if !availableCSVs.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ignore Minimum Length For")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(availableCSVs, id: \.self) { csv in
                                Toggle(
                                    csv,
                                    isOn: Binding(
                                        get: { minLengthExcludedCSVs.contains(csv) },
                                        set: { isOn in
                                            if isOn {
                                                minLengthExcludedCSVs.insert(csv)
                                            } else {
                                                minLengthExcludedCSVs.remove(csv)
                                            }
                                        }
                                    )
                                )
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                Divider()

                Toggle("Fair List Distribution", isOn: $fairWordDistribution)
                    .padding(.horizontal)
            }
            .padding()
        }
        .navigationTitle("Random Words")
    }

    private var appearancesSettings: some View {
        ScrollView {
            VStack(spacing: 15) {

                Text("Word Font")
                    .font(.headline)

                Picker("Word Font", selection: $selectedWordFontRaw) {
                    ForEach(availableFonts, id: \.self) { fontName in
                        Text(fontName).tag(fontName)
                    }
                }
                .pickerStyle(.menu)
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

                Divider()

                Text("Orientation")
                    .font(.headline)

                Picker("Orientation", selection: $orientationLockRaw) {
                    ForEach(OrientationLock.allCases, id: \.rawValue) { lock in
                        Text(lock.rawValue).tag(lock.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: orientationLockRaw) {
                    (OrientationLock(rawValue: orientationLockRaw) ?? .none).apply()
                }

                Divider()

                NavigationLink {
                    CustomiseWordScreenView()
                } label: {
                    HStack {
                        Label("Customise Random Word Screen", systemImage: "paintpalette")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                }
                .foregroundStyle(.primary)
            }
            .padding()
        }
        .navigationTitle("Appearances")
    }
}
