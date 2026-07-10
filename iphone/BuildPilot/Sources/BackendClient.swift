import Foundation

/// The app's only gateway to a Build Pilot backend.
///
/// Everything above this interface is transport-agnostic: the app neither
/// knows nor cares whether the backend is a Mac on the local network (V1
/// development) or a cloud service reached over 5G (production). Swapping
/// deployments means constructing this client with a different base URL —
/// see BackendLocator.
protocol BackendClient {
    func isReachable() async -> Bool
    func submitVisit(roomScan: Data, audioFile: URL?) async throws -> SessionResponse
}

/// HTTP implementation of the Build Pilot backend API
/// (POST /sessions multipart, GET /health). Works identically against
/// http://<mac>:8787 today and https://api.<domain> later.
struct HTTPBackendClient: BackendClient {
    let baseURL: URL

    enum UploadError: LocalizedError {
        case badStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case let .badStatus(code, body):
                return "Backend returned HTTP \(code): \(body.prefix(200))"
            }
        }
    }

    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            visitLog.info("HTTP health \(baseURL.absoluteString) → \(status)")
            return status == 200
        } catch {
            visitLog.error("HTTP health \(baseURL.absoluteString) failed: \(error.localizedDescription)")
            return false
        }
    }

    func submitVisit(roomScan: Data, audioFile: URL?) async throws -> SessionResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("sessions"))
        request.httpMethod = "POST"
        // Transcription on the backend can take a while for long visits; the
        // session persists server-side, so a timeout is recoverable.
        request.timeoutInterval = 600

        let boundary = "buildpilot-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendPart(&body, boundary: boundary, name: "room_scan",
                   fileName: "room.json", contentType: "application/json", data: roomScan)
        if let audioFile, let audioData = try? Data(contentsOf: audioFile) {
            appendPart(&body, boundary: boundary, name: "audio",
                       fileName: "visit.m4a", contentType: "audio/mp4", data: audioData)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UploadError.badStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionResponse.self, from: data)
    }

    /// Archives a visit photo to the backend's session directory (the
    /// permanent project record). Best-effort: the phone keeps its own copy.
    func uploadPhoto(sessionID: String, kind: String, jpeg: Data) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("sessions/\(sessionID)/photos"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60

        let boundary = "buildpilot-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"kind\"\r\n\r\n\(kind)\r\n".utf8))
        appendPart(&body, boundary: boundary, name: "photo",
                   fileName: "photo.jpg", contentType: "image/jpeg", data: jpeg)
        body.append(Data("--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UploadError.badStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    private func appendPart(_ body: inout Data, boundary: String, name: String,
                            fileName: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
}

/// Answers exactly one question: which backend should this visit use?
///
/// Resolution order:
/// 1. `productionURL` — the fixed cloud endpoint. Setting this single
///    constant is the entire phone-side cloud migration; discovery and
///    manual configuration are then bypassed.
/// 2. The user-configured URL from Settings.
/// 3. Bonjour discovery of a local Mac — a DEVELOPMENT convenience for the
///    V1 local prototype, never part of the production path.
enum BackendLocator {
    /// Set when the cloud backend ships, e.g. URL(string: "https://api.buildpilot.example").
    static let productionURL: URL? = nil

    static func locate(configuredURLString: String) async -> URL? {
        if let productionURL {
            return productionURL
        }
        if !configuredURLString.isEmpty, let url = URL(string: configuredURLString) {
            return url
        }
        return await BackendDiscovery.quickFind()
    }
}
