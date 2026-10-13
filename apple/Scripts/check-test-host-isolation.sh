#!/bin/bash
# TaskforceTests를 빌드할 때마다 도는 단계다 (project.yml의 preBuildScripts).
# 테스트 호스트(Taskforce.app)는 테스트가 도는 동안 진짜 앱처럼 시작하고, 호스트의 UserDefaults.standard는 그 번들 ID의 설정 도메인이다.
# 호스트의 번들 ID · App Group이 실사용 앱과 같으면 테스트가 실사용 앱의 설정 도메인(dev.taskforcelabs.taskforce)을 다시 쓰므로
# 호스트가 뜨기 전, 이 빌드 단계에서 실패시킨다. 대소문자는 구분하지 않는다 (macOS 번들 ID · 설정 파일 이름은 구분하지 않는다).
#
# 입력 (Xcode가 준다): TEST_HOST, SRCROOT. 선택: TF_PROTECTED_BUNDLE_IDS (더 지킬 ID를 공백으로 구분해 더한다. 지키는 쪽으로만 바뀐다)
# 실사용 ID는 Config/Base.xcconfig의 BUNDLE_ID_PREFIX에서 읽는다 (실사용 앱도 이 값으로 빌드된다).
#
# 이 스크립트는 설정 도메인을 읽지도 쓰지도 않는다. 호스트의 Info.plist만 본다.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

[[ -n "${TEST_HOST:-}" ]] || fail "TEST_HOST가 비어 있어 테스트 호스트를 확인할 수 없습니다. 테스트를 시작하지 않습니다."
[[ -n "${SRCROOT:-}" ]] || fail "SRCROOT가 비어 있어 실사용 번들 ID를 읽을 수 없습니다. 테스트를 시작하지 않습니다."

host_app="${TEST_HOST%/Contents/MacOS/*}"
[[ "$host_app" != "$TEST_HOST" && "$host_app" == *.app ]] || fail "TEST_HOST가 앱 안의 실행 파일이 아닙니다: $TEST_HOST"
host_plist="$host_app/Contents/Info.plist"
[[ -f "$host_plist" ]] || fail "테스트 호스트의 Info.plist가 없습니다: $host_plist"

host_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$host_plist" 2>/dev/null || true)
host_group_id=$(/usr/libexec/PlistBuddy -c 'Print :AppGroupID' "$host_plist" 2>/dev/null || true)
[[ -n "$host_bundle_id" && "$host_bundle_id" != *'$('* ]] || fail "테스트 호스트의 번들 ID를 읽을 수 없습니다 ('$host_bundle_id'): $host_plist"

base_config="$SRCROOT/Config/Base.xcconfig"
[[ -f "$base_config" ]] || fail "실사용 번들 ID의 기준 파일이 없습니다: $base_config"
real_prefix=$(sed -n 's/^BUNDLE_ID_PREFIX[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*$/\1/p' "$base_config" | head -n 1)
[[ -n "$real_prefix" && "$real_prefix" != *'$('* ]] || fail "$base_config에서 BUNDLE_ID_PREFIX를 읽을 수 없습니다. 테스트를 시작하지 않습니다."

protected_ids="${real_prefix}.taskforce group.${real_prefix}.taskforce ${TF_PROTECTED_BUNDLE_IDS:-}"
for protected_id in $protected_ids; do
  protected_lower=$(lower "$protected_id")
  if [[ "$(lower "$host_bundle_id")" == "$protected_lower" || "$(lower "$host_group_id")" == "$protected_lower" ]]; then
    {
      echo "error: 테스트 호스트가 실사용 앱과 같은 ID입니다 (번들 ID '$host_bundle_id', App Group '$host_group_id'). 이 ID로 테스트를 시작하면 실사용 앱의 설정 도메인을 다시 씁니다."
      echo "error: 테스트는 Taskforce 스킴의 Test 액션(Debug-Test 설정, 호스트 dev.taskforcelabs.unittest.taskforce)이나 격리 접두어로만 돌립니다:"
      echo "error:   xcodebuild test -project apple/Taskforce.xcodeproj -scheme Taskforce -destination 'platform=macOS'"
      echo "error:   (다른 접두어는 BUNDLE_ID_PREFIX=${real_prefix}.<이름>. 접두어가 실사용 접두어 '${real_prefix}' 그대로면 안 됩니다) 자세히는 apple/README.md '테스트 격리'"
    } >&2
    exit 1
  fi
done

echo "note: 테스트 호스트 번들 ID '$host_bundle_id' (App Group '${host_group_id:-없음}')는 실사용 앱 '${real_prefix}.taskforce'와 다릅니다."
