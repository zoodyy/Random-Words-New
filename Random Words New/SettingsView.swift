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

    let availableCSVs: [String]

    @AppStorage("orientationLock") private var orientationLockRaw: String = OrientationLock.none.rawValue
    @AppStorage(WordVisualKeys.userCustomised) private var wordScreenCustomised = false
    @AppStorage("autoDownloadWordDefinitions") private var autoDownloadWordDefinitions = true
    @AppStorage("saveDownloadedDefinitionsLocally") private var saveDownloadedDefinitionsLocally = true

    @State private var showingDeleteDownloadedAlert = false
    @State private var showingDeleteUserAlert = false

    /// Set when a theme change should also restyle the word screen but the user
    /// has customised it — drives the "switch or keep?" alert.
    @State private var pendingWordScreenScheme: ColorScheme?

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

            NavigationLink {
                dictionarySettings
            } label: {
                Label("Dictionary", systemImage: "character.book.closed")
            }
        }
        .navigationTitle("Settings")
    }

    private var dictionarySettings: some View {
        Form {
            Section {
                Toggle("Automatically Download Word Definitions", isOn: $autoDownloadWordDefinitions)
            } footer: {
                Text("When you open a word's definitions, additional definitions (usually better ones) are downloaded from the internet automatically. The manual download button is hidden unless a download fails.")
            }

            Section {
                Toggle("Save Downloaded Definitions Locally", isOn: $saveDownloadedDefinitionsLocally)
            } footer: {
                Text("Newly downloaded definitions are saved on this device so they're available offline. Turning this off doesn't delete definitions that are already saved.")
            }

            Section {
                Button("Delete Downloaded Definitions", role: .destructive) {
                    showingDeleteDownloadedAlert = true
                }

                Button("Delete User-Made Definitions", role: .destructive) {
                    showingDeleteUserAlert = true
                }
            }
        }
        .navigationTitle("Dictionary")
        .alert("Delete Downloaded Definitions", isPresented: $showingDeleteDownloadedAlert) {
            Button("Delete", role: .destructive) {
                Task { await EnglishDictionaryStore.shared.deleteAllDownloadedDefinitions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete all downloaded definitions from this device? This cannot be undone.")
        }
        .alert("Delete User-Made Definitions", isPresented: $showingDeleteUserAlert) {
            Button("Delete", role: .destructive) {
                Task { await EnglishDictionaryStore.shared.deleteAllUserDefinitions() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete all definitions you have written? This cannot be undone.")
        }
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
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $selectedThemeRaw) {
                    Text("System").tag("System")
                    Text("Light").tag("Light")
                    Text("Dark").tag("Dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedThemeRaw) { oldTheme, newTheme in
                    handleThemeChange(from: oldTheme, to: newTheme)
                }
            }

            Section("Orientation") {
                Picker("Orientation", selection: $orientationLockRaw) {
                    ForEach(OrientationLock.allCases, id: \.rawValue) { lock in
                        Text(lock.rawValue).tag(lock.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: orientationLockRaw) {
                    (OrientationLock(rawValue: orientationLockRaw) ?? .none).apply()
                }
            }

            Section {
                NavigationLink {
                    CustomiseWordScreenView()
                } label: {
                    Label("Customise Random Word Screen", systemImage: "paintpalette")
                }
            }
        }
        .navigationTitle("Appearances")
        .alert("Random Word Screen", isPresented: Binding(
            get: { pendingWordScreenScheme != nil },
            set: { if !$0 { pendingWordScreenScheme = nil } }
        )) {
            Button("Switch") {
                if let scheme = pendingWordScreenScheme {
                    WordScreenPreset.standard(for: scheme).writeToDefaults()
                    // Back on the standard look, so future theme changes may
                    // switch it silently again.
                    wordScreenCustomised = false
                }
                pendingWordScreenScheme = nil
            }
            Button("Keep Current", role: .cancel) {
                pendingWordScreenScheme = nil
            }
        } message: {
            Text("Do you also want to switch the random word screen to the standard \(pendingWordScreenScheme == .dark ? "dark" : "light") look? Your customisations will be replaced.")
        }
    }

    /// The word-screen appearance a theme implies: the theme itself, or the
    /// device's setting when following the system.
    private func wordScreenScheme(forTheme raw: String) -> ColorScheme {
        switch raw {
        case "Light": return .light
        case "Dark":  return .dark
        default:      return WordScreenPreset.deviceColorScheme
        }
    }

    /// When the appearance actually changes: restyle an untouched word screen
    /// silently, or ask first if the user has customised it.
    private func handleThemeChange(from oldTheme: String, to newTheme: String) {
        let newScheme = wordScreenScheme(forTheme: newTheme)
        guard wordScreenScheme(forTheme: oldTheme) != newScheme else { return }

        if wordScreenCustomised {
            pendingWordScreenScheme = newScheme
        } else {
            WordScreenPreset.standard(for: newScheme).writeToDefaults()
        }
    }
}
