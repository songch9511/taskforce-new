import Foundation
import Testing
@testable import TaskforceKit

struct AppConfigTests {
    let valid: [String: Any] = [
        "SupabaseURL": "https://abcd.supabase.co",
        "SupabaseKey": "sb_publishable_123",
        "AppGroupID": "group.dev.taskforcelabs.taskforce",
        "APIBaseURL": "https://taskforce.example.com",
    ]

    @Test func readsValidValues() throws {
        let config = try AppConfig(infoDictionary: valid)
        #expect(config.supabaseURL.absoluteString == "https://abcd.supabase.co")
        #expect(config.supabaseKey == "sb_publishable_123")
        #expect(config.appGroupID == "group.dev.taskforcelabs.taskforce")
        #expect(config.apiBaseURL.absoluteString == "https://taskforce.example.com")
    }

    @Test func allowsLocalHTTPServer() throws {
        var info = valid
        info["APIBaseURL"] = "http://localhost:3000"
        let url = try AppConfig(infoDictionary: info).apiBaseURL
        #expect(url.host == "localhost")
        #expect(url.port == 3000)
    }

    @Test func rejectsAPIBaseURLWithPath() {
        var info = valid
        info["APIBaseURL"] = "https://taskforce.example.com/api/v1"
        #expect(throws: AppConfig.ConfigError.invalidURL(key: "APIBaseURL", value: "https://taskforce.example.com/api/v1")) {
            try AppConfig(infoDictionary: info)
        }
    }

    @Test func rejectsMissingAPIBaseURL() {
        var info = valid
        info["APIBaseURL"] = "$(API_BASE_URL)"
        #expect(throws: AppConfig.ConfigError.missing("APIBaseURL")) { try AppConfig(infoDictionary: info) }
    }

    @Test func allowsTrailingSlash() throws {
        var info = valid
        info["SupabaseURL"] = "https://abcd.supabase.co/"
        #expect(try AppConfig(infoDictionary: info).supabaseURL.host == "abcd.supabase.co")
    }

    @Test(arguments: ["https://abcd.supabase.co/rest/v1/", "abcd.supabase.co", "https://", "ftp://abcd.supabase.co"])
    func rejectsBadURL(_ url: String) {
        var info = valid
        info["SupabaseURL"] = url
        #expect(throws: AppConfig.ConfigError.invalidURL(key: "SupabaseURL", value: url)) { try AppConfig(infoDictionary: info) }
    }

    @Test(arguments: ["", "   ", "$(SUPABASE_KEY)"])
    func rejectsMissingKey(_ key: String) {
        var info = valid
        info["SupabaseKey"] = key
        #expect(throws: AppConfig.ConfigError.missing("SupabaseKey")) { try AppConfig(infoDictionary: info) }
    }

    @Test func rejectsAbsentAppGroup() {
        var info = valid
        info.removeValue(forKey: "AppGroupID")
        #expect(throws: AppConfig.ConfigError.missing("AppGroupID")) { try AppConfig(infoDictionary: info) }
    }
}
