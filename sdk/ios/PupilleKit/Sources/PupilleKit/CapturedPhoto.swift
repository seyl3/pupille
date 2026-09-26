import Foundation

/// A photo taken by `PupilleCameraView`. Host apps can't create one from arbitrary
/// bytes, so `PupilleClient.publish` only ever signs camera output.
public struct CapturedPhoto: Identifiable, Sendable {
    public let id = UUID()
    /// Encoded JPEG bytes exactly as the camera produced them.
    public let imageData: Data
    public let capturedAt: Date

    init(imageData: Data, capturedAt: Date = Date()) {
        self.imageData = imageData
        self.capturedAt = capturedAt
    }
}
