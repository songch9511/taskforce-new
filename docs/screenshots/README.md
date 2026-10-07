# README 앱 화면

이 폴더의 이미지는 실제 SwiftUI 앱 뷰를 `SampleData` 예시 데이터로 렌더한 것입니다. 실제 계정·연결 서비스·개인 업무 데이터는 사용하지 않았습니다. 운영 동기화나 로그인 검증을 보여주는 이미지는 아닙니다.

- 생성일: 2026-10-07
- 앱 소스: `07d8ca91f2a891363e0c12443e2a5d45479ed8b1`
- 생성기: `apple/TaskforceTests/LauncherPresentationFixtureRendersTests.swift`
- 데이터: `apple/Taskforce/Shared/SampleData.swift`
- 해상도: 1520 × 960 px, light / dark
- 별도 합성·리터칭 없음. Offscreen 렌더이므로 바탕화면의 유리 효과는 포함되지 않습니다.

저장소 루트에서 예제 `Secrets.xcconfig`를 준비한 뒤 실행합니다. 기존 설정은 덮어쓰지 않습니다.

```sh
test -e apple/Config/Secrets.xcconfig || cp apple/Config/Secrets.example.xcconfig apple/Config/Secrets.xcconfig
xcodebuild test \
  -project apple/Taskforce.xcodeproj \
  -scheme Taskforce \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/taskforce-github-showcase-build \
  -only-testing:TaskforceTests/LauncherPresentationFixtureRendersTests \
  CODE_SIGNING_ALLOWED=NO
```

출력 위치는 테스트 로그의 `Wrote synthetic fixture renders to ...`에서 확인합니다.

| 원본 파일 | README 파일 |
|---|---|
| `fixture-launcher-collapsed-light.png` | `mac-tasks-light.png` |
| `fixture-launcher-collapsed-dark.png` | `mac-tasks-dark.png` |
| `fixture-launcher-expanded-sources-light.png` | `mac-source-light.png` |
