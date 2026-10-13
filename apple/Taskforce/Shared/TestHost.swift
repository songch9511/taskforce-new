import Foundation

/// 이 프로세스가 앱을 호스트로 띄운 XCTest 실행인지.
/// Mac 시험은 앱 자신을 호스트로 띄운다. 호스트는 실제 계정 · 알림 · 전역 단축키 · 설정 이전을 시작하지 않고 자기 설정 도메인도 만들지 않는다
/// (`apple/README.md` "테스트 격리"). 시작 코드(`TaskforceApp.init` · `MacAppDelegate.applicationDidFinishLaunching`)는 판단을 복사하지 않고 여기를 부른다.
enum TestHost {
    /// - environment: XCTest가 시험 번들을 올리면서 넣는 `XCTestConfigurationFilePath`가 있으면 호스트
    /// - testCaseClassLoaded: 환경이 비워져도 XCTest가 올라와 있으면(`XCTestCase` 클래스) 호스트
    static func isTestHost(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        testCaseClassLoaded: Bool = NSClassFromString("XCTestCase") != nil
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil || testCaseClassLoaded
    }
}
