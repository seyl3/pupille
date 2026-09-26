#if os(iOS)
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Full-screen camera with flash, 0.5×/1×/2× zoom, tap to focus, front/rear switch and a
/// review step. Present it as a sheet or full-screen cover; it dismisses itself.
/// It is the only way for a host app to get a `CapturedPhoto`.
/// The host app needs `NSCameraUsageDescription` in its Info.plist.
public struct PupilleCameraView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraSession()
    @State private var accepted = false
    @State private var shutterDown = false
    private let onCapture: (CapturedPhoto) -> Void
    private let onFailure: ((PupilleError) -> Void)?

    /// - Parameters:
    ///   - onCapture: Called with the photo after the user taps **Use photo**.
    ///   - onFailure: Called if the camera closes with an error.
    public init(onCapture: @escaping (CapturedPhoto) -> Void, onFailure: ((PupilleError) -> Void)? = nil) {
        self.onCapture = onCapture
        self.onFailure = onFailure
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let data = camera.imageData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Captured photo preview")
            } else {
                CameraPreview(session: camera.session, onFocus: { camera.focus(at: $0) })
                    .ignoresSafeArea(edges: .bottom)
            }
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 20)
                if let error = camera.error {
                    Text(error).font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center).padding(16)
                        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 24)
                }
                if camera.imageData == nil { cameraControls } else { reviewControls }
            }
            .foregroundStyle(.white)
        }
        .statusBarHidden()
        .task { await camera.start() }
        .onDisappear {
            camera.stop()
            if accepted, let data = camera.imageData {
                onCapture(CapturedPhoto(imageData: data))
            } else if let error = camera.error {
                onFailure?(.camera(error))
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold))
                    .frame(width: 48, height: 48).background(.black.opacity(0.55), in: Circle())
            }.accessibilityLabel("Close camera")
            Spacer()
            if camera.imageData == nil && camera.hasFlash {
                Button { camera.cycleFlash() } label: {
                    Image(systemName: camera.flashSymbol).font(.system(size: 18, weight: .semibold))
                        .frame(width: 48, height: 48).background(.black.opacity(0.55), in: Circle())
                }.accessibilityLabel("Flash \(camera.flashLabel). Tap to change")
            } else {
                Color.clear.frame(width: 48, height: 48)
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 18).padding(.top, 10)
    }

    private var cameraControls: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                ForEach(camera.availableZooms, id: \.self) { factor in
                    Button { camera.setZoom(factor) } label: {
                        Text(factor == 0.5 ? "0.5×" : factor == 1 ? "1×" : "2×")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(camera.zoom == factor ? .black : .white)
                            .frame(width: 46, height: 46)
                            .background(camera.zoom == factor ? Color.white : Color.black.opacity(0.58), in: Circle())
                    }.accessibilityLabel("\(factor) times zoom")
                }
            }.buttonStyle(.plain)
            HStack {
                Color.clear.frame(width: 64, height: 64)
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.easeOut(duration: 0.08)) { shutterDown = true }
                    camera.capture()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeOut(duration: 0.18)) { shutterDown = false }
                    }
                } label: {
                    Circle().fill(.white).frame(width: 62, height: 62).padding(5)
                        .overlay(Circle().stroke(.white, lineWidth: 3))
                        .scaleEffect(shutterDown ? 0.87 : 1)
                }
                .disabled(!camera.isReady || camera.isCapturing)
                .accessibilityLabel("Take photo")
                Spacer()
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    camera.flip()
                } label: {
                    Image(systemName: "camera.rotate").font(.system(size: 26, weight: .medium))
                        .frame(width: 64, height: 64)
                }
                .disabled(!camera.isReady || camera.isCapturing)
                .accessibilityLabel("Switch to \(camera.position == .back ? "front" : "rear") camera")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 26).padding(.top, 20).padding(.bottom, 24)
        .background(.black.opacity(0.9))
    }

    private var reviewControls: some View {
        HStack(spacing: 12) {
            Button("Retake") { camera.imageData = nil }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(Color.white.opacity(0.16), in: Capsule())
            Button("Use photo") { accepted = true; dismiss() }
                .foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(.white, in: Capsule())
        }
        .font(.headline).buttonStyle(.plain)
        .padding(.horizontal, 24).padding(.vertical, 30).background(.black.opacity(0.9))
    }

}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let onFocus: (CGPoint) -> Void
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        let recognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(recognizer)
        return view
    }
    func updateUIView(_ view: PreviewView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFocus: onFocus) }

    final class Coordinator: NSObject {
        let onFocus: (CGPoint) -> Void
        init(onFocus: @escaping (CGPoint) -> Void) { self.onFocus = onFocus }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view as? PreviewView else { return }
            let point = recognizer.location(in: view)
            view.showFocus(at: point)
            onFocus(view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    private let focusBox = UIView()

    func showFocus(at point: CGPoint) {
        focusBox.removeFromSuperview()
        focusBox.frame = CGRect(x: point.x - 36, y: point.y - 36, width: 72, height: 72)
        focusBox.layer.borderWidth = 2
        focusBox.layer.borderColor = UIColor.systemYellow.cgColor
        focusBox.layer.cornerRadius = 8
        focusBox.alpha = 1
        focusBox.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        addSubview(focusBox)
        UIView.animate(withDuration: 0.16) { self.focusBox.transform = .identity }
        UIView.animate(withDuration: 0.4, delay: 0.5) { self.focusBox.alpha = 0 }
    }
}

@MainActor
private final class CameraSession: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "PupilleKit.camera")

    @Published var imageData: Data?
    @Published var error: String?
    @Published var isReady = false
    @Published var isCapturing = false
    @Published var position: AVCaptureDevice.Position = .back
    @Published var flashMode: AVCaptureDevice.FlashMode = .auto
    @Published var hasFlash = false
    @Published var zoom: CGFloat = 1
    @Published var supportsUltraWide = false

    var availableZooms: [CGFloat] {
        position == .back ? (supportsUltraWide ? [0.5, 1, 2] : [1, 2]) : [1]
    }
    private var ultraWide: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera], mediaType: .video, position: .back
        ).devices.first
    }
    var flashSymbol: String {
        switch flashMode {
        case .on: "bolt.fill"
        case .auto: "bolt.badge.a"
        default: "bolt.slash"
        }
    }
    var flashLabel: String {
        switch flashMode {
        case .on: "on"
        case .auto: "auto"
        default: "off"
        }
    }

    func start() async {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard authorized else {
            error = "Camera permission denied. Enable it in Settings → Pupille → Camera."
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            error = "No rear camera found"
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                error = "Could not configure camera"
                return
            }
            session.addInput(input)
            session.addOutput(output)
            session.sessionPreset = .photo
            session.commitConfiguration()
            hasFlash = device.hasFlash
            supportsUltraWide = ultraWide != nil
            let captureSession = session
            queue.async {
                captureSession.startRunning()
                DispatchQueue.main.async {
                    self.isReady = captureSession.isRunning
                    if !captureSession.isRunning { self.error = "Camera could not start" }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func cycleFlash() {
        switch flashMode {
        case .auto: flashMode = .on
        case .on: flashMode = .off
        default: flashMode = .auto
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func focus(at point: CGPoint) {
        guard isReady, let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        queue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.unlockForConfiguration()
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription }
            }
        }
    }

    func setZoom(_ factor: CGFloat) {
        guard isReady, position == .back else { return }
        if factor == 0.5, let ultraWide {
            switchCamera(to: ultraWide, targetPosition: .back, targetZoom: 0.5)
            return
        }
        guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
        if device.deviceType == .builtInUltraWideCamera,
           let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            switchCamera(to: wide, targetPosition: .back, targetZoom: factor)
            return
        }
        let selected = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        queue.async {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = selected
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoom = factor }
            } catch {
                DispatchQueue.main.async { self.error = error.localizedDescription }
            }
        }
    }

    func flip() {
        guard isReady else { return }
        let nextPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        guard let nextDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: nextPosition) else {
            error = "That camera is unavailable"
            return
        }
        switchCamera(to: nextDevice, targetPosition: nextPosition, targetZoom: 1)
    }

    private func switchCamera(to nextDevice: AVCaptureDevice,
                              targetPosition: AVCaptureDevice.Position, targetZoom: CGFloat) {
        isReady = false
        error = nil
        let captureSession = session
        queue.async {
            do {
                let nextInput = try AVCaptureDeviceInput(device: nextDevice)
                captureSession.beginConfiguration()
                let previousInput = captureSession.inputs.first as? AVCaptureDeviceInput
                if let previousInput { captureSession.removeInput(previousInput) }
                if captureSession.canAddInput(nextInput) {
                    captureSession.addInput(nextInput)
                    captureSession.commitConfiguration()
                    let hardwareZoom: CGFloat = targetZoom == 0.5 ? 1 : targetZoom
                    do {
                        try nextDevice.lockForConfiguration()
                        nextDevice.videoZoomFactor = min(max(hardwareZoom,
                            nextDevice.minAvailableVideoZoomFactor), nextDevice.maxAvailableVideoZoomFactor)
                        nextDevice.unlockForConfiguration()
                    } catch {
                        DispatchQueue.main.async { self.error = error.localizedDescription }
                    }
                    DispatchQueue.main.async {
                        self.position = targetPosition
                        self.hasFlash = nextDevice.hasFlash
                        self.zoom = targetZoom
                        self.isReady = true
                    }
                } else {
                    if let previousInput { captureSession.addInput(previousInput) }
                    captureSession.commitConfiguration()
                    DispatchQueue.main.async {
                        self.isReady = true
                        self.error = "Could not switch cameras"
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isReady = true
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func capture() {
        guard isReady, !isCapturing else { return }
        isCapturing = true
        error = nil
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.flashMode = hasFlash && output.supportedFlashModes.contains(flashMode) ? flashMode : .off
        output.capturePhoto(with: settings, delegate: self)
    }

    func stop() {
        let captureSession = session
        queue.async { captureSession.stopRunning() }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            self.isCapturing = false
            if let error { self.error = error.localizedDescription }
            else if let data { self.imageData = data }
            else { self.error = "Camera returned no image bytes" }
        }
    }
}
#endif
