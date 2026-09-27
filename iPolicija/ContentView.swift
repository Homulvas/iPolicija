import SwiftUI
import PhotosUI
import CoreLocation

struct ContentView: View {
    @State private var image: UIImage?
    @State private var showCamera = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var report = ReportData()
    @State private var isRecognizing = false
    @State private var ocrDebug = ""
    @State private var plateCandidates: [String] = []
    @State private var isResolvingAddress = false
    @StateObject private var locationManager = LocationManager()
    @StateObject private var epolicija = EpolicijaController()
    @State private var showReport = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                    }
                    // Separate rows: two buttons in one Form row share a single tap target,
                    // so tapping "Choose from Library" used to open the camera.
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                    }
                }

                Section {
                    if isRecognizing {
                        ProgressView("Reading plate…")
                    }
                    TextField("Plate", text: $report.plate)
                        .textInputAutocapitalization(.characters)
                    if plateCandidates.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                Text("Or:")
                                    .foregroundStyle(.secondary)
                                // A button style makes each chip its own tap target inside the Form row.
                                ForEach(plateCandidates.filter { $0 != report.plate }, id: \.self) { candidate in
                                    Button(candidate) { report.plate = candidate }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                } header: {
                    Text("License plate")
                } footer: {
                    #if DEBUG
                    if !ocrDebug.isEmpty {
                        Text("Text found in photo: \(ocrDebug)")
                            .textSelection(.enabled)
                    }
                    #endif
                }

                Section("Offence") {
                    Picker("Type", selection: $report.offence) {
                        ForEach(OffenceType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section {
                    if isResolvingAddress {
                        ProgressView("Finding address…")
                    }
                    TextField("Vietovė (town)", text: $report.city)
                    TextField("Gatvė (street)", text: $report.street)
                    TextField("Namo numeris", text: $report.house)
                } header: {
                    Text("Location")
                } footer: {
                    switch report.locationSource {
                    case .photo: Text("From the photo's GPS data.")
                    case .device: Text("Photo had no GPS data — using your current location.")
                    case .none: Text(image == nil ? "" : "Photo has no location. Enter the address.")
                    }
                }

                Section("Date/time") {
                    DatePicker("", selection: $report.date)
                        .labelsHidden()
                }

                Section {
                    Text(report.descriptionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("Extra details (optional)", text: $report.note, axis: .vertical)
                } header: {
                    Text("Description")
                }

                Section {
                    Button {
                        epolicija.start(payload: report.formPayload(photo: image))
                        showReport = true
                    } label: {
                        Label("Prepare report on epolicija.lt", systemImage: "paperplane")
                    }
                    .disabled(!canPrepare)
                } footer: {
                    Text(canPrepare
                         ? "Fills in the form and ticks the declarations. You review it and send it yourself."
                         : "Needs a photo, a plate and a town.")
                }
            }
            .navigationTitle("iPolicija")
            .sheet(isPresented: $showReport) {
                ReportSheet(controller: epolicija)
            }
            .onChange(of: photoPickerItem) { _, newItem in
                Task {
                    // Load the original file bytes (not a UIImage) so EXIF/GPS survive.
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let uiImage = UIImage(data: data) {
                        await handleNewImage(uiImage, data: data)
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { uiImage in
                    // In-app camera photos carry no GPS: use current location and now.
                    Task { await handleNewImage(uiImage, data: nil) }
                }
                .ignoresSafeArea()
            }
            .onAppear {
                locationManager.requestLocation()
            }
        }
    }

    private var canPrepare: Bool {
        image != nil && !report.plate.isEmpty && !report.city.isEmpty
    }

    @MainActor
    private func handleNewImage(_ uiImage: UIImage, data: Data?) async {
        image = uiImage
        report = ReportData(offence: report.offence)

        isRecognizing = true
        ocrDebug = ""
        plateCandidates = []
        PlateOCR.recognizePlate(in: uiImage) { candidates, texts in
            DispatchQueue.main.async {
                isRecognizing = false
                ocrDebug = texts.isEmpty ? "(nothing)" : texts.joined(separator: " | ")
                plateCandidates = candidates
                if let best = candidates.first { report.plate = best }
            }
        }

        let meta = data.map { PhotoMetadata.read(from: $0) } ?? PhotoMetadata()
        report.date = meta.date ?? Date()

        guard let choice = chooseLocation(photo: meta) else { return }
        let (location, source) = choice
        report.coordinate = location.coordinate
        report.locationSource = source

        isResolvingAddress = true
        if let address = await AddressResolver.resolve(location) {
            report.apply(address, source: source)
        }
        isResolvingAddress = false
    }

    /// Photo GPS wins. Current location is only trusted for photos taken in the last 15 minutes.
    private func chooseLocation(photo meta: PhotoMetadata) -> (CLLocation, LocationSource)? {
        if let location = meta.location {
            return (location, .photo)
        }
        let takenRecently = abs((meta.date ?? Date()).timeIntervalSinceNow) < 15 * 60
        if takenRecently, let current = locationManager.location {
            return (current, .device)
        }
        return nil
    }
}
