import Foundation

public enum PupilleError: LocalizedError, Equatable {
    case invalidBackendURL
    case invalidResponse
    case notEnrolled
    case appAttestUnsupported
    case secureEnclaveKeyUnavailable
    case randomFailure
    case worldProofFailed(String)
    case humanAlreadyRegistered
    case handleTaken
    case notAJPEG
    case proofTooLarge
    case camera(String)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBackendURL: "Enter a valid backend URL"
        case .invalidResponse: "Unexpected backend response"
        case .notEnrolled: "Create your World verified profile first"
        case .appAttestUnsupported: "App Attest unavailable on this iPhone"
        case .secureEnclaveKeyUnavailable: "Could not create Secure Enclave key"
        case .randomFailure: "Could not create profile ID"
        case .worldProofFailed(let reason): "World proof failed: \(reason)"
        case .humanAlreadyRegistered: "This World identity already has a profile on this backend."
        case .handleTaken: "That handle is already taken. Choose another name."
        case .notAJPEG: "Not a JPEG file"
        case .proofTooLarge: "The proof does not fit in the image"
        case .camera(let message): message
        case .server(let message): message
        }
    }
}
