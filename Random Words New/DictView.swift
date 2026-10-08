import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DictView: View {
    
    @Binding var selectedCSVs: Set<String>
    @Binding var words: [String]
    @Binding var csvRanges: [String: (Double, Double)]
    
    @State private var csvFiles: [String] = []
    
    @State private var csvToEdit: String?
    
    @State private var showingNewCSVAlert = false
    @State private var newCSVName = ""
    
    @State private var showingImportPicker = false
    @State private var showingAddOptions = false
    
    @State private var showingShareOptions = false
    @State private var shareSelectedCSVs: Set<String> = []
    @State private var exportRanges = false
    @State private var shareItem: ExportShareItem?
    
    @State private var csvPreviewInfo: [String: CSVPreviewInfo] = [:]

    @State private var listMidX: CGFloat?

    @AppStorage(FavouriteWordlists.storageKey) private var favouriteCSVsData: Data = Data()

    private var favouriteCSVs: Set<String> {
        FavouriteWordlists.decode(favouriteCSVsData)
    }

    private struct CSVPreviewInfo {
        let lines: WordlistFile.Lines
        let lowerWord: String
        let upperWord: String
    }
    
    private var orderedCSVFiles: [String] {
        let favourites = favouriteCSVs
        let selected = csvFiles.filter { selectedCSVs.contains($0) }
        let unselected = csvFiles.filter { !selectedCSVs.contains($0) }

        // Favourites lead within each group, but never rise above a selected list.
        func favouritesFirst(_ files: [String]) -> [String] {
            files.filter { favourites.contains($0) } + files.filter { !favourites.contains($0) }
        }

        return favouritesFirst(selected) + favouritesFirst(unselected)
    }
    
    private var activeCSVFiles: [String] {
        orderedCSVFiles.filter { selectedCSVs.contains($0) }
    }
    
    var body: some View {
        List {
            ForEach(orderedCSVFiles, id: \.self) { file in
                VStack(alignment: .leading, spacing: 8) {

                    // The boundary words can run to several lines (long
                    // phrases), so they toggle the list just like its name.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(file)

                            if favouriteCSVs.contains(file) {
                                Image(systemName: "star.fill")
                                    .imageScale(.small)
                                    .foregroundColor(.yellow)
                            }

                            Spacer()

                            if selectedCSVs.contains(file) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.green)
                            }
                        }

                        if selectedCSVs.contains(file) {
                            let range = csvRanges[file] ?? (0.0, 1.0)
                            let preview = csvPreviewInfo[file]
                            let lowerWord = preview?.lowerWord ?? "-"
                            let upperWord = preview?.upperWord ?? "-"

                            Text("\(Int(range.0 * 100))% (\(lowerWord))  -  \(Int(range.1 * 100))% (\(upperWord))")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleSelection(file)
                    }

                    if selectedCSVs.contains(file) {
                        RangeSlider(
                            lowerValue: Binding(
                                get: { csvRanges[file]?.0 ?? 0.0 },
                                set: { newValue in
                                    let upper = csvRanges[file]?.1 ?? 1.0
                                    csvRanges[file] = (min(newValue, upper), upper)
                                    refreshPreviewInfo(for: file, reusingLines: true)
                                }
                            ),
                            upperValue: Binding(
                                get: { csvRanges[file]?.1 ?? 1.0 },
                                set: { newValue in
                                    let lower = csvRanges[file]?.0 ?? 0.0
                                    csvRanges[file] = (lower, max(newValue, lower))
                                    refreshPreviewInfo(for: file, reusingLines: true)
                                }
                            )
                        )
                    }
                }
                .swipeActions(edge: .trailing) {
                    // The first action sits on the outer edge, so it's the one
                    // a full swipe triggers.
                    Button {
                        toggleFavourite(file)
                    } label: {
                        if favouriteCSVs.contains(file) {
                            Label("Unfavourite", systemImage: "star.fill")
                        } else {
                            Label("Favourite", systemImage: "star")
                                // Swipe actions fill their symbols by default,
                                // which would make this look favourited already.
                                .environment(\.symbolVariants, .none)
                        }
                    }
                    .tint(.yellow)

                    Button {
                        csvToEdit = file
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).midX
        } action: { midX in
            listMidX = midX
        }
        .navigationTitle("Select Word Lists")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                CenteredNavigationTitle(title: "Select Word Lists", centerX: listMidX)
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    shareSelectedCSVs = Set(orderedCSVFiles)
                    exportRanges = true
                    showingShareOptions = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(orderedCSVFiles.isEmpty)
                
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
            allowedContentTypes: [.commaSeparatedText, .folder, .plainText],
            allowsMultipleSelection: true
        ) { result in
            handleImport(result: result)
        }
        .sheet(isPresented: $showingShareOptions) {
            NavigationStack {
                List {
                    Section("CSV Files") {
                        ForEach(orderedCSVFiles, id: \.self) { file in
                            Button {
                                if shareSelectedCSVs.contains(file) {
                                    shareSelectedCSVs.remove(file)
                                } else {
                                    shareSelectedCSVs.insert(file)
                                }
                            } label: {
                                HStack {
                                    Text(file)
                                        .foregroundColor(.primary)
                                    
                                    Spacer()
                                    
                                    if shareSelectedCSVs.contains(file) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                    
                    Section {
                        Toggle("Export ranges", isOn: $exportRanges)
                    }
                }
                .navigationTitle("Export CSVs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            showingShareOptions = false
                        }
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Share") {
                            do {
                                let folderURL = try createExportFolder()
                                showingShareOptions = false
                                shareItem = ExportShareItem(url: folderURL)
                            } catch {
                                print("Export failed: \(error)")
                            }
                        }
                        .disabled(shareSelectedCSVs.isEmpty)
                    }
                }
            }
        }
        .sheet(item: $shareItem, onDismiss: {
            if let url = shareItem?.url {
                try? FileManager.default.removeItem(at: url)
            }
        }) { item in
            ActivityView(activityItems: [item.url]) {
                try? FileManager.default.removeItem(at: item.url)
                shareItem = nil
            }
        }
        .onAppear {
            loadBundledCSVs()
            loadUserCSVs()
            refreshAllSelectedPreviewInfo()
        }
        .onReceive(NotificationCenter.default.publisher(for: .csvDeleted)) { notification in
            if let deletedName = notification.object as? String {
                csvFiles.removeAll { $0 == deletedName }
                selectedCSVs.remove(deletedName)
                shareSelectedCSVs.remove(deletedName)
                csvRanges[deletedName] = nil
                csvPreviewInfo[deletedName] = nil
                if favouriteCSVs.contains(deletedName) {
                    var favourites = favouriteCSVs
                    favourites.remove(deletedName)
                    favouriteCSVsData = FavouriteWordlists.encode(favourites)
                }
            }
        }
    }

    private func toggleFavourite(_ file: String) {
        var favourites = favouriteCSVs
        if favourites.contains(file) {
            favourites.remove(file)
        } else {
            favourites.insert(file)
        }
        favouriteCSVsData = FavouriteWordlists.encode(favourites)
    }
    
    private func createExportFolder() throws -> URL {
        let tempRoot = FileManager.default.temporaryDirectory
        let exportFolderURL = tempRoot.appendingPathComponent("CSVExport-\(UUID().uuidString)", isDirectory: true)
        
        try FileManager.default.createDirectory(at: exportFolderURL, withIntermediateDirectories: true)
        
        let selectedFilesInOrder = orderedCSVFiles.filter { shareSelectedCSVs.contains($0) }
        
        for file in selectedFilesInOrder {
            let sourceURL = getReadableURL(for: file)
            let destinationURL = exportFolderURL.appendingPathComponent("\(file).csv")
            
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        }
        
        if exportRanges {
            let txtURL = exportFolderURL.appendingPathComponent("ranges.txt")
            let txtContent = selectedFilesInOrder.map { file in
                guard selectedCSVs.contains(file) else {
                    return "\(file)=0-0"
                }
                let range = csvRanges[file] ?? (0.0, 1.0)
                let lowerPercent = Int(range.0 * 100)
                let upperPercent = Int(range.1 * 100)
                return "\(file)=\(lowerPercent)-\(upperPercent)"
            }
            .joined(separator: "\n")
            
            try txtContent.write(to: txtURL, atomically: true, encoding: .utf8)
        }
        
        return exportFolderURL
    }
    
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
        refreshPreviewInfo(for: trimmed)
        
        newCSVName = ""
    }
    
    private func handleImport(result: Result<[URL], Error>) {
        do {
            let selectedURLs = try result.get()
            guard !selectedURLs.isEmpty else { return }
            
            for selectedURL in selectedURLs {
                let accessing = selectedURL.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        selectedURL.stopAccessingSecurityScopedResource()
                    }
                }
                
                let resourceValues = try? selectedURL.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = resourceValues?.isDirectory ?? false
                
                if isDirectory {
                    try importFolder(from: selectedURL)
                } else {
                    let ext = selectedURL.pathExtension.lowercased()
                    
                    switch ext {
                    case "csv":
                        try importSingleCSV(from: selectedURL)
                    case "txt":
                        try importTXT(from: selectedURL)
                    default:
                        break
                    }
                }
            }
            
            refreshAllSelectedPreviewInfo()
            
        } catch {
            print("Import failed: \(error)")
        }
    }
    
    private func importSingleCSV(from selectedFile: URL) throws {
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
        if csvRanges[cleanedName] == nil {
            csvRanges[cleanedName] = (0.0, 1.0)
        }
        
        refreshPreviewInfo(for: cleanedName)
    }
    
    private func importFolder(from folderURL: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        
        var importedCSVNames: [String] = []
        var txtURL: URL?
        
        for fileURL in contents {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                continue
            }
            
            let ext = fileURL.pathExtension.lowercased()
            
            if ext == "csv" {
                let importedName = try copyCSVToDocuments(from: fileURL)
                if !importedName.isEmpty {
                    importedCSVNames.append(importedName)
                }
            } else if ext == "txt" && txtURL == nil {
                txtURL = fileURL
            }
        }
        
        if let txtURL {
            try applyTXT(from: txtURL)
        } else {
            for name in importedCSVNames {
                selectedCSVs.insert(name)
                if csvRanges[name] == nil {
                    csvRanges[name] = (0.0, 1.0)
                }
                refreshPreviewInfo(for: name)
            }
        }
    }
    
    private func importTXT(from txtURL: URL) throws {
        try applyTXT(from: txtURL)
    }
    
    @discardableResult
    private func copyCSVToDocuments(from sourceURL: URL) throws -> String {
        let fileName = sourceURL
            .deletingPathExtension()
            .lastPathComponent
        
        let cleanedName = fileName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".csv", with: "")
        
        guard !cleanedName.isEmpty else { return "" }
        
        let destinationURL = getDocumentsURL(for: cleanedName)
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        
        if !csvFiles.contains(cleanedName) {
            csvFiles.insert(cleanedName, at: 0)
        }
        
        return cleanedName
    }
    
    private func applyTXT(from txtURL: URL) throws {
        let content = try String(contentsOf: txtURL, encoding: .utf8)
        let parsedRanges = parseTXT(content)
        
        selectedCSVs.removeAll()
        
        for existingFile in csvFiles {
            csvRanges[existingFile] = nil
            csvPreviewInfo[existingFile] = nil
        }
        
        for (fileName, range) in parsedRanges {
            let fileExistsLocally = FileManager.default.fileExists(atPath: getDocumentsURL(for: fileName).path)
            
            if fileExistsLocally {
                if !csvFiles.contains(fileName) {
                    csvFiles.insert(fileName, at: 0)
                }

                // A 0-0 range marks a CSV that was exported while inactive
                if range.0 == 0.0 && range.1 == 0.0 {
                    continue
                }

                selectedCSVs.insert(fileName)
                csvRanges[fileName] = range
                refreshPreviewInfo(for: fileName)
            }
        }
    }
    
    private func parseTXT(_ content: String) -> [String: (Double, Double)] {
        var result: [String: (Double, Double)] = [:]
        
        let lines = content.components(separatedBy: .newlines)
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            
            let parts = line.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            
            let fileName = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let rangePart = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            
            let rangeValues = rangePart.components(separatedBy: "-")
            guard rangeValues.count == 2 else { continue }
            
            let lowerPercentString = rangeValues[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let upperPercentString = rangeValues[1].trimmingCharacters(in: .whitespacesAndNewlines)
            
            guard
                let lowerPercent = Double(lowerPercentString),
                let upperPercent = Double(upperPercentString)
            else {
                continue
            }
            
            let lower = min(max(lowerPercent / 100.0, 0.0), 1.0)
            let upper = min(max(upperPercent / 100.0, lower), 1.0)
            
            guard !fileName.isEmpty else { continue }
            result[fileName] = (lower, upper)
        }
        
        return result
    }
    
    private func loadBundledCSVs() {
        for name in BundledWordlists.names() {
            if !csvFiles.contains(name) {
                csvFiles.append(name)
            }
        }
    }

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
    
    private func getReadableURL(for name: String) -> URL {
        let documentsURL = getDocumentsURL(for: name)
        if FileManager.default.fileExists(atPath: documentsURL.path) {
            return documentsURL
        }
        
        if let bundleURL = BundledWordlists.url(named: name) {
            return bundleURL
        }
        
        return documentsURL
    }
    
    private func toggleSelection(_ file: String) {
        if selectedCSVs.contains(file) {
            selectedCSVs.remove(file)
            shareSelectedCSVs.remove(file)
            csvRanges[file] = nil
            csvPreviewInfo[file] = nil
        } else {
            selectedCSVs.insert(file)
            if csvRanges[file] == nil {
                csvRanges[file] = (0.0, 1.0)
            }
            refreshPreviewInfo(for: file)
        }
    }
    
    private func refreshAllSelectedPreviewInfo() {
        for file in selectedCSVs {
            refreshPreviewInfo(for: file)
        }
    }
    
    /// Updates the words shown at the ends of `file`'s range. The list is read
    /// again to pick up edits, unless `reusingLines`: a slider step only moves
    /// the range, so it reuses the lines found before and reads just the two
    /// words.
    private func refreshPreviewInfo(for file: String, reusingLines: Bool = false) {
        let range = csvRanges[file] ?? (0.0, 1.0)
        let lines = (reusingLines ? csvPreviewInfo[file]?.lines : nil)
            ?? WordlistFile.Lines(at: getReadableURL(for: file))
        
        guard !lines.isEmpty else {
            csvPreviewInfo[file] = CSVPreviewInfo(lines: lines, lowerWord: "-", upperWord: "-")
            return
        }
        
        let lowerIndex = min(Int(Double(lines.count - 1) * range.0), lines.count - 1)
        let upperIndex = min(Int(Double(lines.count - 1) * range.1), lines.count - 1)
        
        let lowerWord = lines.indices.contains(lowerIndex) ? lines[lowerIndex] : "-"
        let upperWord = lines.indices.contains(upperIndex) ? lines[upperIndex] : "-"
        
        csvPreviewInfo[file] = CSVPreviewInfo(
            lines: lines,
            lowerWord: lowerWord,
            upperWord: upperWord
        )
    }
}

private struct ExportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    
    let activityItems: [Any]
    var completion: (() -> Void)? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            completion?()
        }
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}

/// A navigation bar title that stays centred on screen.
///
/// UIKit only centres a title while it keeps a wide margin to the bar
/// buttons. The share and add buttons are wide enough that on a 6.1" iPhone
/// it left-aligns the title instead, so this asks for the whole space between
/// the buttons and shifts the text back to the middle, as far as it fits.
private struct CenteredNavigationTitle: View {

    let title: String
    /// The screen's centre, in the global coordinate space. Twice this is
    /// also the screen's width.
    let centerX: CGFloat?

    @State private var textWidth: CGFloat = 0
    @State private var slotFrame: CGRect = .zero

    private var offset: CGFloat {
        guard let centerX else { return 0 }
        let room = max((slotFrame.width - textWidth) / 2, 0)
        return min(max(centerX - slotFrame.midX, -room), room)
    }

    var body: some View {
        Text(title)
            .font(.headline)
            // Like the system title, which keeps its size at any text size.
            .dynamicTypeSize(...DynamicTypeSize.large)
            .lineLimit(1)
            .accessibilityAddTraits(.isHeader)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                textWidth = width
            }
            .offset(x: offset)
            // UIKit shrinks a screen-wide title to the space between the buttons.
            .frame(idealWidth: (centerX ?? 0) * 2, maxWidth: .infinity)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .global)
            } action: { frame in
                slotFrame = frame
            }
    }
}

/// A slider with a thumb at each end of the chosen part of 0...1.
private struct RangeSlider: UIViewRepresentable {

    @Binding var lowerValue: Double
    @Binding var upperValue: Double

    func makeUIView(context: Context) -> RangeSliderView {
        RangeSliderView()
    }

    func updateUIView(_ view: RangeSliderView, context: Context) {
        view.setValues(lower: Float(lowerValue), upper: Float(upperValue))
        view.lowerValueChanged = { lowerValue = Double($0) }
        view.upperValueChanged = { upperValue = Double($0) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RangeSliderView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: uiView.intrinsicContentSize.height)
    }
}

/// Two system sliders sharing one track, as UIKit has no range slider.
///
/// The sliders lie on top of each other showing only their thumbs, over a
/// track filled in between them. A touch goes to the thumb under it, and
/// neither thumb can be dragged past the other.
private final class RangeSliderView: UIView {

    var lowerValueChanged: ((Float) -> Void)?
    var upperValueChanged: ((Float) -> Void)?

    private let lowerSlider = UISlider()
    private let upperSlider = UISlider()

    /// Stands in for the sliders' own tracks: they're see-through, so two
    /// stacked would darken each other. (A track configuration's
    /// `neutralValue` can start the fill at the lower thumb, but iOS 26.2
    /// doesn't redraw it when that changes.)
    private let track = UIView()
    private let fill = UIView()

    /// Thumbs are smaller than a comfortable touch target, so they catch
    /// touches this far around them too.
    private let minimumTouchSize: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)

        // The colours of the system slider's track.
        track.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.1)
                : UIColor(white: 0, alpha: 0.1)
        }
        fill.backgroundColor = .tintColor
        for view in [track, fill] {
            view.layer.cornerCurve = .continuous
        }
        track.clipsToBounds = true
        track.addSubview(fill)
        addSubview(track)

        upperSlider.value = 1
        upperSlider.accessibilityLabel = "Range end"
        upperSlider.addTarget(self, action: #selector(upperSliderChanged), for: .valueChanged)

        lowerSlider.accessibilityLabel = "Range start"
        lowerSlider.addTarget(self, action: #selector(lowerSliderChanged), for: .valueChanged)

        for slider in [upperSlider, lowerSlider] {
            slider.minimumTrackTintColor = .clear
            slider.maximumTrackTintColor = .clear
            addSubview(slider)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: upperSlider.intrinsicContentSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        lowerSlider.frame = bounds
        upperSlider.frame = bounds
        track.frame = upperSlider.convert(upperSlider.trackRect(forBounds: upperSlider.bounds), to: self)
        track.layer.cornerRadius = track.bounds.height / 2
        updateFill()
    }

    func setValues(lower: Float, upper: Float) {
        // Assigning a value, even an unchanged one, can disturb a drag.
        if lowerSlider.value != lower { lowerSlider.value = lower }
        if upperSlider.value != upper { upperSlider.value = upper }
        updateFill()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, alpha > 0.01 else { return nil }

        let slider = slider(for: point)
        let thumb = thumbFrame(of: slider)
        let touchArea = thumb.insetBy(
            dx: min(thumb.width - minimumTouchSize, 0) / 2,
            dy: min(thumb.height - minimumTouchSize, 0) / 2
        )
        // Touches away from the thumbs fall through, so the row still swipes.
        guard touchArea.contains(point) else { return nil }
        return slider.hitTest(convert(point, to: slider), with: event) ?? slider
    }

    /// The slider whose thumb a touch at `point` is meant for.
    private func slider(for point: CGPoint) -> UISlider {
        let lowerX = thumbFrame(of: lowerSlider).midX
        let upperX = thumbFrame(of: upperSlider).midX

        guard abs(upperX - lowerX) < 1 else {
            return abs(point.x - lowerX) <= abs(point.x - upperX) ? lowerSlider : upperSlider
        }

        // The thumbs are stacked: hand out one that can still move, picking by
        // the side of the thumb that was touched when both can.
        if upperSlider.value >= upperSlider.maximumValue { return lowerSlider }
        if lowerSlider.value <= lowerSlider.minimumValue { return upperSlider }
        return point.x < lowerX ? lowerSlider : upperSlider
    }

    private func thumbFrame(of slider: UISlider) -> CGRect {
        let bounds = slider.bounds
        let track = slider.trackRect(forBounds: bounds)
        let thumb = slider.thumbRect(forBounds: bounds, trackRect: track, value: slider.value)
        return slider.convert(thumb, to: self)
    }

    @objc private func lowerSliderChanged() {
        if lowerSlider.value > upperSlider.value {
            lowerSlider.value = upperSlider.value
        }
        updateFill()
        lowerValueChanged?(lowerSlider.value)
    }

    @objc private func upperSliderChanged() {
        if upperSlider.value < lowerSlider.value {
            upperSlider.value = lowerSlider.value
        }
        updateFill()
        upperValueChanged?(upperSlider.value)
    }

    /// Fills the track from one thumb's centre to the other's.
    private func updateFill() {
        let lowerX = thumbFrame(of: lowerSlider).midX - track.frame.minX
        let upperX = thumbFrame(of: upperSlider).midX - track.frame.minX
        fill.frame = CGRect(x: lowerX, y: 0, width: max(upperX - lowerX, 0), height: track.bounds.height)
        fill.layer.cornerRadius = fill.bounds.height / 2
    }
}
