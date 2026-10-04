import Foundation

struct AppConfiguration: Sendable {
    let apiBaseURL: URL

    static let live: AppConfiguration = {
        let configuredValue = Bundle.main.object(
            forInfoDictionaryKey: "FIRAS_API_BASE_URL"
        ) as? String
        let value = configuredValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        #if DEBUG
        let development = true
        #else
        let development = false
        #endif

        guard let value,
              let url = URL(string: value),
              CloudEndpointPolicy.permitsBaseURL(url, development: development)
        else {
            return AppConfiguration(apiBaseURL: URL(string: "https://firasai.org")!)
        }

        return AppConfiguration(apiBaseURL: url)
    }()

}
