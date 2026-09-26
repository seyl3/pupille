@preconcurrency import AVFoundation
import CryptoKit
import SwiftUI
import UIKit

struct CameraCheckView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraCheckSession()
    let onResult: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let imageData = camera.imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("Captured \(imageData.count) bytes")
                        .font(.footnote.monospaced())
                } else {
                    CameraPreview(session: camera.session)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    if let error = camera.error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Button(camera.imageData == nil ? "Take photo" : "Retake") {
                    if camera.imageData == nil {
                        camera.capture()
                    } else {
                        camera.imageData = nil
                    }
                }
                .font(.headline)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.primary, in: Capsule())
                .buttonStyle(.plain)
                .disabled(!camera.isReady && camera.imageData == nil)
            }
            .padding()
            .navigationTitle("Camera check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await camera.start() }
        .onDisappear {
            camera.stop()
            if let data = camera.imageData {
                let digest = SHA256.hash(data: data)
                let prefix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
                onResult("PASS: Captured \(data.count) bytes. SHA-256 starts \(prefix)")
            } else if let error = camera.error {
                onResult("FAIL: \(error)")
            }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

@MainActor
private final class CameraCheckSession: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "app.pupille.camera")

    @Published var imageData: Data?
    @Published var error: String?
    @Published var isReady = false

    func start() async {
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorized = true
        case .notDetermined:
            authorized = await AVCaptureDevice.requestAccess(for: .video)
        default:
            authorized = false
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
            session.commitConfiguration()
            isReady = true
            let captureSession = session
            queue.async { captureSession.startRunning() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func capture() {
        guard isReady else { return }
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func stop() {
        let captureSession = session
        queue.async { captureSession.stopRunning() }
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            if let error {
                self.error = error.localizedDescription
            } else if let data {
                self.imageData = data
            } else {
                self.error = "Camera returned no image bytes"
            }
        }
    }
}
