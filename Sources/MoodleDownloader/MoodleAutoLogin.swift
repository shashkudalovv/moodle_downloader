import Foundation
import Security

struct MoodleMobileCredentials: Codable, Sendable {
    let token: String
    let privateToken: String
    let userID: Int
}

enum MoodleCredentialStore {
    private static let service = "dev.vibecode.moodledownloader"
    private static let account = "moodle-mobile-autologin"

    static func load() -> MoodleMobileCredentials? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(MoodleMobileCredentials.self, from: data)
    }

    static func save(_ credentials: MoodleMobileCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        let identity: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func remove() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum MoodleAutoLoginService {
    private struct KeyResponse: Decodable {
        let key: String
        let autologinurl: String
    }

    static func makeLoginURL(credentials: MoodleMobileCredentials) async -> URL? {
        guard let endpoint = URL(string: "https://moodle.innopolis.university/webservice/rest/server.php") else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("MoodleMobile", forHTTPHeaderField: "User-Agent")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "moodlewsrestformat", value: "json"),
            URLQueryItem(name: "wsfunction", value: "tool_mobile_get_autologin_key"),
            URLQueryItem(name: "wstoken", value: credentials.token),
            URLQueryItem(name: "privatetoken", value: credentials.privateToken)
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpAdditionalHeaders = ["User-Agent": "MoodleMobile"]
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let keyResponse = try? JSONDecoder().decode(KeyResponse.self, from: data),
                  var components = URLComponents(string: keyResponse.autologinurl) else { return nil }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "userid", value: String(credentials.userID)))
            items.append(URLQueryItem(name: "key", value: keyResponse.key))
            items.append(URLQueryItem(name: "urltogo", value: "/my/courses.php"))
            components.queryItems = items
            return components.url
        } catch {
            return nil
        }
    }
}
