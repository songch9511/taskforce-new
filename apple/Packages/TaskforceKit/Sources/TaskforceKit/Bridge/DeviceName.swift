#if os(macOS)
import Foundation
import SystemConfiguration

// Mac 기기 이름을 서버에 표시용으로 보낸다 (OA F1m, 서버 F1s `src/lib/bridge/device-name.ts`).
// 이름은 화면에 보이는 글자일 뿐이다: 식별(device_id · device_ref)에 쓰지 않고, 로그 · 오류 문구 · 지표 · AI 입력에 넣지 않는다.
// 이 파일은 순수 규칙 둘(정규화 · 보내도 되는 빌드 판정)과 이름의 실제 원천 하나다.

public enum DeviceName {
    /// 서버 정규화 뒤 이름의 한도 (`BRIDGE_DEVICE_NAME_MAX`)
    public static let maxCodePoints = 64

    /// 서버와 같은 정규화 (`normalizeDeviceName`, 같은 시험 표 `Fixtures/bridge-v1/device-name.json`을 양쪽이 읽는다):
    /// 공백 종류(탭 · 줄바꿈 · 폭 있는 공백 `Z*`)는 공백 하나로 → 제어(Cc) · 서식(Cf: 양방향 제어 · 폭 없는 문자) 제거 → NFC → 공백 덩어리를 하나로 · 앞뒤 trim →
    /// 글자소(grapheme) 중간을 자르지 않고 64 코드 포인트까지 → 다시 trim. 비면 nil (키를 뺀다)
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if isWhitespaceLike(scalar) {
                scalars.append(" ")
                continue
            }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate: continue
            default: scalars.append(scalar)
            }
        }
        // 공백 덩어리는 코드 포인트 단위로 하나로 합친다 (서버 `/ {2,}/`): Swift의 문자열 비교는 글자소(공백 + 결합 문자 = 한 글자)로 보므로 `replacingOccurrences`를 쓰지 않는다
        var collapsed = String.UnicodeScalarView()
        for scalar in String(scalars).precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar == " ", collapsed.last == " " { continue }
            collapsed.append(scalar)
        }
        let text = String(collapsed).trimmingCharacters(in: CharacterSet(charactersIn: " "))
        var kept = ""
        var points = 0
        for character in text {
            let size = character.unicodeScalars.count
            if points + size > maxCodePoints { break }
            kept.append(character)
            points += size
        }
        kept = kept.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return kept.isEmpty ? nil : kept
    }

    /// JS `/[\p{Z}\t\n\v\f\r\u0085]/u`: 공백 구분자(Zs) · 줄 구분자(Zl) · 문단 구분자(Zp)와 제어 공백 여섯
    private static func isWhitespaceLike(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: break
        }
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x85: return true
        default: return false
        }
    }

    /// 이름의 원천: 시스템 설정의 컴퓨터 이름 (`SCDynamicStoreCopyComputerName`). `Host.current().localizedName` · `ProcessInfo.hostName`은 쓰지 않는다 (네트워크 상태에 따라 바뀌는 값)
    public static func current() -> String? {
        SCDynamicStoreCopyComputerName(nil, nil) as String?
    }
}

/// 이름을 서버로 보내도 되는 빌드 · 서버인가 (OA F1s notes 8장 위험 2): 처리방침 갱신 전에 개발 빌드가 운영 서버로 이름을 보내지 않게 한다.
/// Debug는 loopback 서버(개발용 로컬 스택)일 때만, Release는 bridge가 켜진 빌드에서만이다 (호스트가 `BRIDGE_ENABLED`로 런타임 자체를 만들지 않는다)
public enum DeviceNamePolicy {
    public static func allowsSending(isDebugBuild: Bool, apiBaseURL: URL) -> Bool {
        isDebugBuild ? BridgeEndpointPolicy.isLoopback(apiBaseURL) : true
    }

    /// 런타임 구성에 넣는 공급자: 보내도 되는 때만 현재 이름을 준다 (아니면 nil — 런타임은 키를 싣지 않는다)
    public static func provider(isDebugBuild: Bool, apiBaseURL: URL, source: @escaping @Sendable () -> String? = { DeviceName.current() }) -> (@Sendable () -> String?)? {
        allowsSending(isDebugBuild: isDebugBuild, apiBaseURL: apiBaseURL) ? source : nil
    }
}
#endif
