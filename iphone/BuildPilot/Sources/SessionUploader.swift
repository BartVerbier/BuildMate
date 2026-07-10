import Foundation

/// Uploads the visit bundle (CapturedRoom JSON + audio) to the Mac backend
/// and decodes the completed session with its draft estimate.
struct SessionUploader {
    let backendURL: URL

    enum UploadError: LocalizedError {
        case badStatus(Int, String)

        var errorDescription: String? {
            switch self {
            case let .badStatus(code, body):
                return "Backend returned HTTP \(code): \(body.prefix(200))"
            }
        }
    }

    func upload(roomScan: Data, audioFile: URL?) async throws -> SessionResponse {
        var request = URLRequest(url: backendURL.appendingPathComponent("sessions"))
        request.httpMethod = "POST"
        // Whisper on a long visit can take a while; the session directory on
        // the Mac persists everything, so a timeout is recoverable via GET.
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

    private func appendPart(_ body: inout Data, boundary: String, name: String,
                            fileName: String, contentType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
        body.append(Data("Content-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
}
