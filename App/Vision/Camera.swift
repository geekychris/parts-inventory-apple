import AVFoundation
import SwiftUI
import Vision

/// A camera the app can use: built in, Continuity Camera, or plugged in (USB on a Mac, USB-C on an iPad).
struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String
}

/// The live camera for Scan and Identify: one capture session, the camera chosen in the picker (remembered),
/// still photos, and — while scanning — the bar codes and 2-D codes in view.
@Observable
final class Camera {
    enum State: Equatable { case idle, starting, running, denied, noCamera, failed(String) }

    private(set) var devices: [CameraDevice] = []
    private(set) var current: CameraDevice?
    private(set) var state: State = .idle
    /// Called with each new code in view while `scanning` is on.
    @ObservationIgnored var onCode: ((String) -> Void)?

    @ObservationIgnored let worker = CameraWorker()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static let chosenKey = "cameraDevice"

    /// The cameras that are connected now.
    nonisolated static func available() -> [CameraDevice] {
        discover().map { d in CameraDevice(id: d.uniqueID, name: d.localizedName, kind: describe(d)) }
    }

    nonisolated static func discover() -> [AVCaptureDevice] {
        #if os(macOS)
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        #else
        // The back camera as one device (it switches lenses itself, macro included), the front camera, and plugged-in ones.
        let back = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera],
                                                    mediaType: .video, position: .back).devices.first
        let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        let external = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        return [back, front].compactMap { $0 } + external
        #endif
    }

    nonisolated static func describe(_ d: AVCaptureDevice) -> String {
        if d.isContinuityCamera { return "Continuity Camera" }
        switch d.deviceType {
        case .external: return "Plugged in"
        #if os(macOS)
        case .continuityCamera: return "Continuity Camera"
        case .deskViewCamera: return "Desk View"
        #endif
        default:
            switch d.position {
            case .back: return "Back"
            case .front: return "Front"
            default: return "Built in"
            }
        }
    }

    init() {
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            })
        }
        worker.onCodes = { [weak self] codes in
            Task { @MainActor in for c in codes { self?.onCode?(c) } }
        }
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        worker.stop()
    }

    /// Whether to look for codes in the live picture.
    var scanning: Bool {
        get { worker.scanning }
        set { worker.scanning = newValue }
    }

    func start() async {
        state = .starting
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        default: state = .denied; return
        }
        devices = Self.available()
        await use(preferred())
    }

    func stop() {
        worker.stop()
        state = .idle
    }

    /// Switch to another camera, and remember it.
    func select(_ id: String) async {
        UserDefaults.standard.set(id, forKey: Self.chosenKey)
        await use(devices.first { $0.id == id })
    }

    /// A still photo from the current camera, as JPEG.
    func capture() async -> Data? { await worker.capture() }

    /// The camera chosen before if it's connected, otherwise the one the system prefers (a plugged-in or
    /// Continuity camera on a Mac), otherwise the first.
    private func preferred() -> CameraDevice? {
        if let id = UserDefaults.standard.string(forKey: Self.chosenKey), let d = devices.first(where: { $0.id == id }) { return d }
        if let sys = AVCaptureDevice.systemPreferredCamera, let d = devices.first(where: { $0.id == sys.uniqueID }) { return d }
        return devices.first
    }

    private func use(_ device: CameraDevice?) async {
        guard let device else { current = nil; state = .noCamera; worker.stop(); return }
        current = device
        state = .starting
        do {
            try await worker.run(deviceID: device.id)
            state = .running
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func devicesChanged() {
        devices = Self.available()
        guard state != .idle, state != .denied else { return }
        // The camera in use was unplugged, or one appeared when there was none: pick again.
        if current.map({ c in !devices.contains(c) }) ?? true { Task { await use(preferred()) } }
    }
}

/// The capture session, run on its own queue.
nonisolated final class CameraWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.session")
    private let frames = DispatchQueue(label: "camera.frames")
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var _scanning = false
    private var lastScan = Date.distantPast
    private var seen: [String: Date] = [:]
    /// Rotation for photos, so they come out the way up the preview shows (iPhone and iPad).
    private var _captureAngle: CGFloat = 0
    var onCodes: (@Sendable ([String]) -> Void)?

    var scanning: Bool {
        get { lock.withLock { _scanning } }
        set { lock.withLock { _scanning = newValue } }
    }
    var captureAngle: CGFloat {
        get { lock.withLock { _captureAngle } }
        set { lock.withLock { _captureAngle = newValue } }
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    func run(deviceID: String) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do { try configure(deviceID: deviceID); k.resume() } catch { k.resume(throwing: error) }
            }
        }
    }

    func stop() {
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    private func configure(deviceID: String) throws {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else { throw Failure(errorDescription: "That camera isn’t connected.") }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration(); if !session.isRunning { session.startRunning() } }
        session.inputs.forEach(session.removeInput)
        guard session.canAddInput(input) else { throw Failure(errorDescription: "\(device.localizedName) can’t be used.") }
        session.addInput(input)
        if session.outputs.isEmpty {
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: frames)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }
        // Full photo resolution where the camera has it; plain webcams fall back to their best video size.
        for p in [AVCaptureSession.Preset.photo, .high] where session.canSetSessionPreset(p) { session.sessionPreset = p; break }
        // Close-ups of chips: keep refocusing.
        if device.isFocusModeSupported(.continuousAutoFocus), (try? device.lockForConfiguration()) != nil {
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
        }
    }

    // MARK: Photos

    func capture() async -> Data? {
        await withCheckedContinuation { (k: CheckedContinuation<Data?, Never>) in
            queue.async { [self] in
                guard session.isRunning, photoOutput.connection(with: .video) != nil else { k.resume(returning: nil); return }
                if let c = photoOutput.connection(with: .video), c.isVideoRotationAngleSupported(captureAngle) { c.videoRotationAngle = captureAngle }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                photoOutput.capturePhoto(with: settings, delegate: PhotoDelegate { k.resume(returning: $0) })
            }
        }
    }

    private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        private var done: ((Data?) -> Void)?
        private var keep: PhotoDelegate?
        init(_ done: @escaping (Data?) -> Void) { self.done = done; super.init(); keep = self }
        func photoOutput(_ o: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            done?(error == nil ? photo.fileDataRepresentation() : nil)
            done = nil; keep = nil
        }
    }

    // MARK: Codes in the live picture

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard scanning, Date.now.timeIntervalSince(lastScan) > 0.25, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        lastScan = .now
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.dataMatrix, .qr, .microQR, .pdf417, .code128, .code39, .ean13, .upce]
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        let now = Date.now
        // The same code stays in view for a while: report it again only after it's been gone 5 s.
        let codes = (request.results ?? []).compactMap(\.payloadStringValue).filter { c in
            defer { seen[c] = now }
            return seen[c].map { now.timeIntervalSince($0) > 5 } ?? true
        }
        if !codes.isEmpty { onCodes?(codes) }
    }
}

// MARK: - Views

/// The live picture from a capture session.
struct CameraPreview {
    let worker: CameraWorker
}

#if os(macOS)
extension CameraPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: worker.session)
        layer.videoGravity = .resizeAspect
        v.layer = layer
        v.wantsLayer = true
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
#else
extension CameraPreview: UIViewRepresentable {
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var rotation: AVCaptureDevice.RotationCoordinator?
        var watches: [NSKeyValueObservation] = []
    }
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.preview.session = worker.session
        v.preview.videoGravity = .resizeAspect
        return v
    }
    /// Keep the picture (and photos) upright as the device turns, for whichever camera is in use.
    func updateUIView(_ v: PreviewView, context: Context) {
        guard let device = (worker.session.inputs.first as? AVCaptureDeviceInput)?.device, v.rotation?.device != device else { return }
        let r = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: v.preview)
        v.rotation = r
        let worker = worker
        v.watches = [
            r.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak v] r, _ in
                let angle = r.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor in v?.preview.connection?.videoRotationAngle = angle }
            },
            r.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { r, _ in
                worker.captureAngle = r.videoRotationAngleForHorizonLevelCapture
            },
        ]
    }
}
#endif

/// The camera with a picker for which one to use, and a shutter button.
struct CameraView: View {
    let camera: Camera
    var shutterTitle = "Take a photo"
    var onPhoto: (Data) -> Void
    @State private var taking = false

    // The controls sit above the picture, not over it: on a Mac the live preview draws on top of anything laid over it.
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                if camera.devices.count > 1 { picker }
                #if os(macOS)
                DeviceImportButton(title: "Use iPhone camera") { onPhoto($0) }
                #endif
                Spacer()
                Button {
                    taking = true
                    Task { if let d = await camera.capture() { onPhoto(d) }; taking = false }
                } label: { Label(shutterTitle, systemImage: "camera.circle.fill") }
                    .accessibilityLabel(shutterTitle)
                    .buttonStyle(.borderedProminent)
                    .disabled(camera.state != .running || taking)
            }
            ZStack {
                Color.black
                switch camera.state {
                case .denied:
                    message("Camera access is off", "Allow e-Parts Inventory Manager to use the camera in System Settings › Privacy & Security › Camera.", "video.slash")
                case .noCamera:
                    message("No camera", "Connect a camera — it’s picked up as soon as it’s plugged in.", "video.slash")
                case .failed(let e):
                    message("The camera didn’t start", e, "exclamationmark.triangle")
                default:
                    CameraPreview(worker: camera.worker)
                        .id(camera.current?.id)
                    if camera.state == .starting { ProgressView().tint(.white) }
                }
            }
            .clipShape(.rect(cornerRadius: 16))
        }
    }

    var picker: some View {
        Menu {
            Picker("Camera", selection: Binding(get: { camera.current?.id ?? "" }, set: { id in Task { await camera.select(id) } })) {
                ForEach(camera.devices) { d in Text("\(d.name) — \(d.kind)").tag(d.id) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(camera.current?.name ?? "Camera", systemImage: "web.camera")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
    }

    func message(_ title: String, _ text: String, _ icon: String) -> some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(text)).foregroundStyle(.white)
    }
}
