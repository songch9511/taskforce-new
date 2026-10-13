import SwiftUI

/// Highlight (0.2.0 디자인 시스템 Atoms): 웹사이트의 형광펜. "당신을 기다림"에만 쓴다 (Review 단어, 원문에서 바뀐 구절).
/// 다른 강조에는 쓰지 않는다. 밑줄은 쓰지 않는다.
public extension View {
    /// 글자 하나 전체를 칠한다 ("Needs your answer")
    func markerHighlight() -> some View {
        foregroundStyle(TFColor.textOnMarker)
            .padding(.horizontal, 2)
            .background(TFColor.fillMarker, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

public enum MarkerText {
    /// 문장 안에서 바뀐 구절만 칠한다 (원문 인용). 구절이 없으면 문장 그대로다
    public static func attributed(_ text: String, highlighting phrase: String?) -> AttributedString {
        var result = AttributedString(text)
        guard let phrase, !phrase.isEmpty, let range = result.range(of: phrase) else { return result }
        result[range][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = TFColor.fillMarker
        result[range][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = TFColor.textOnMarker
        return result
    }

    /// 칠할 구절이 문장 안에 있나 (없으면 칠하지 않는다)
    public static func contains(_ text: String, phrase: String?) -> Bool {
        guard let phrase, !phrase.isEmpty else { return false }
        return text.contains(phrase)
    }
}

#Preview("Highlight") {
    VStack(alignment: .leading, spacing: 12) {
        Text("Needs your answer").font(TFFont.meta).markerHighlight()
        Text(MarkerText.attributed("Could we do the core launch on Thursday instead?", highlighting: "Thursday"))
            .font(TFFont.callout)
            .foregroundStyle(TFColor.textPrimary)
    }
    .padding()
}
