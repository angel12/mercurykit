import Foundation
import MercuryKit

func loadVoiceResponse(_ request: URLRequest, session: URLSession) async throws -> Data {
    let (data, _) = try await HTTPErrorDetail.load(request, on: session)
    return data
}

func displayVoiceError(_ text: String) -> String {
    HTTPErrorDetail.displayed(text)
}
