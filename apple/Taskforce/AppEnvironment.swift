import SwiftUI
import TaskforceKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

extension EnvironmentValues {
    /// Startup이 만든 서비스 묶음 (설정이 빠졌으면 nil)
    @Entry var services: AppServices?
}

/// 화면 이동 경로. 두 탭 모두 같은 목적지를 쓴다 (할 일 → 원문, 원문 → 할 일).
struct ActionRoute: Hashable {
    let id: UUID
}

struct SourceRoute: Hashable {
    let id: UUID
    /// 열었을 때 보여줄 근거 구절
    var focusQuote: String?
}

extension View {
    func taskforceDestinations(services: AppServices) -> some View {
        navigationDestination(for: ActionRoute.self) { route in
            ActionDetailView(actionID: route.id, services: services)
        }
        .navigationDestination(for: SourceRoute.self) { route in
            SourceDetailView(route: route, services: services)
        }
    }

    /// 오류 · 안내 한 줄을 알림으로
    func messageAlert(_ message: Binding<String?>) -> some View {
        alert(
            message.wrappedValue ?? "",
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("확인", role: .cancel) {}
        }
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

enum DisplayDate {
    static let korean = Locale(identifier: "ko_KR")

    /// "9월 24일 (목) 오전 11:00"
    static func full(_ date: Date) -> String {
        date.formatted(.dateTime.locale(korean).month().day().weekday(.abbreviated).hour().minute())
    }

    /// "9월 24일"
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.locale(korean).month().day())
    }

    /// "3시간 전"
    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named).locale(korean))
    }

    /// 기한 선택기의 Date ↔ 기한 날짜. 선택기는 기기 시간대로 날짜를 보여준다.
    static func localDate(from date: Date) -> LocalDate {
        LocalDate(date: date, timeZone: .current)
    }

    static func pickerDate(from date: LocalDate) -> Date {
        var components = DateComponents(year: date.year, month: date.month, day: date.day, hour: 12)
        components.timeZone = .current
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }
}

/// 기한 한 줄 ("내일 · 9월 28일(월)")
struct DueLabel: View {
    let due: LocalDate
    var overdue: Bool {
        due < DueDateFormat.today()
    }

    var body: some View {
        Label(DueDateFormat.summary(due, today: DueDateFormat.today()), systemImage: "calendar")
            .foregroundStyle(overdue ? .red : .secondary)
    }
}

/// 랭킹 이유 칩
struct ReasonChip: View {
    let reason: RankReason

    var body: some View {
        Text(reason.label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(reason.isUrgent ? Color.red : Color.secondary)
            .background((reason.isUrgent ? Color.red : Color.secondary).opacity(0.12), in: Capsule())
    }
}
