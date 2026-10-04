#!/usr/bin/env bash
# Mac 앱 DMG 배포: 아카이브 → Developer ID 내보내기 → 공증 · 스테이플 → DMG → 서명 · 공증 · 스테이플 → Gatekeeper 확인.
# 저장소 맨 위에서 실행한다. 절차 · 일회성 준비(공증 프로필)는 docs/go-live/mac-dmg.md.
#
#   scripts/release-mac-dmg.sh --version 0.1.0 --build 2 [--profile taskforce-notary] [--out dist] [--skip-notarize]
#
# --skip-notarize: 공증 · 스테이플을 건너뛰는 시험용. 만든 DMG는 배포하면 안 된다(Gatekeeper가 막는다).
set -euo pipefail

TEAM_ID="${TEAM_ID:-U9DWQKQFMW}"
PROD_API_HOST="api.taskforcelabs.dev"
EXPORT_OPTIONS="apple/Config/ExportOptions-DeveloperID.plist"

VERSION=""
BUILD=""
PROFILE="taskforce-notary"
OUT="dist"
SKIP_NOTARIZE=0

usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\n오류: %s\n' "$*" >&2; exit 1; }

while (( $# > 0 )); do
  case "$1" in
    --version)  [[ $# -ge 2 ]] || fail "--version 값이 없습니다"; VERSION="$2"; shift 2 ;;
    --build)    [[ $# -ge 2 ]] || fail "--build 값이 없습니다"; BUILD="$2"; shift 2 ;;
    --profile)  [[ $# -ge 2 ]] || fail "--profile 값이 없습니다"; PROFILE="$2"; shift 2 ;;
    --out)      [[ $# -ge 2 ]] || fail "--out 값이 없습니다"; OUT="$2"; shift 2 ;;
    --skip-notarize) SKIP_NOTARIZE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; fail "모르는 인자: $1" ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { usage >&2; fail "--version은 0.1.0 같은 형식이어야 합니다"; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { usage >&2; fail "--build는 정수여야 합니다"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$OUT" = /* ]] || OUT="$ROOT/$OUT"

NAME="Taskforce-$VERSION-$BUILD"
RUN_DIR="$OUT/$NAME"
LOG_DIR="$RUN_DIR/logs"
ARCHIVE="$RUN_DIR/Taskforce.xcarchive"
DERIVED="$RUN_DIR/DerivedData"
EXPORT_DIR="$RUN_DIR/export"
APP="$EXPORT_DIR/Taskforce.app"
DMG="$RUN_DIR/$NAME.dmg"

# xcodebuild 등을 로그 파일로 돌리고, 실패하면 오류 줄과 끝 30줄을 그대로 보여 준다.
run_logged() {
  local log="$1"; shift
  if ! "$@" >"$log" 2>&1; then
    printf '\n실패한 명령: %s\n로그 전체: %s\n' "$*" "$log" >&2
    grep -E 'error:|Error:|error ' "$log" | head -20 >&2 || true
    printf -- '--- 로그 끝 30줄 ---\n' >&2
    tail -n 30 "$log" >&2
    if grep -qE 'No Accounts|No profiles for' "$log"; then
      printf '\n프로필 발급 문제입니다: Xcode → Settings → Accounts에 팀 %s의 Apple ID가 로그인돼 있어야 합니다 (docs/go-live/mac-dmg.md 6장).\n' "$TEAM_ID" >&2
    fi
    exit 1
  fi
}

# 공증 제출 → Accepted가 아니면 notarytool log를 보여 주고 멈춘다. 인자: 파일, 라벨
notarize() {
  local file="$1" label="$2" out="$LOG_DIR/notary-$label.txt" id
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$out" || true
  if ! grep -q '^ *status: Accepted$' "$out"; then
    id="$(awk '$1 == "id:" { print $2; exit }' "$out")"
    printf '\n공증 실패(%s). notarytool log:\n' "$label" >&2
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    else
      printf '제출 id가 없습니다(업로드 전에 실패). 위 출력을 확인하세요.\n' >&2
    fi
    exit 1
  fi
}

# ---------------------------------------------------------------- 사전 점검
step "사전 점검"
for tool in xcodebuild hdiutil ditto codesign shasum plutil spctl; do
  command -v "$tool" >/dev/null || fail "$tool 을(를) 찾을 수 없습니다"
done
xcrun --find notarytool >/dev/null 2>&1 || fail "xcrun notarytool 을(를) 찾을 수 없습니다 (Xcode 13 이상 필요)"

IDENTITY_LINE="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | grep "($TEAM_ID)" | head -1 || true)"
[[ -n "$IDENTITY_LINE" ]] || fail "팀 $TEAM_ID 의 \"Developer ID Application\" 인증서가 키체인에 없습니다 (security find-identity -v -p codesigning)"
IDENTITY_HASH="$(awk '{ print $2 }' <<<"$IDENTITY_LINE")"
IDENTITY_NAME="$(sed -E 's/^[^"]*"([^"]*)".*/\1/' <<<"$IDENTITY_LINE")"
echo "서명 인증서: $IDENTITY_NAME"

[[ -f apple/Config/Secrets.xcconfig ]] || fail "apple/Config/Secrets.xcconfig 이 없습니다 (Supabase URL · 키. apple/README.md 처음 한 번 1번)"
echo "apple/Config/Secrets.xcconfig: present"
[[ -f "$EXPORT_OPTIONS" ]] || fail "$EXPORT_OPTIONS 이 없습니다"

if (( SKIP_NOTARIZE )); then
  echo "공증 프로필: 건너뜀 (--skip-notarize)"
else
  NOTARY_ERR="$(mktemp)"
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>"$NOTARY_ERR"; then
    cat "$NOTARY_ERR" >&2; rm -f "$NOTARY_ERR"
    fail "공증 프로필 \"$PROFILE\" 을(를) 쓸 수 없습니다. 먼저: xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id $TEAM_ID (docs/go-live/mac-dmg.md 1장)"
  fi
  rm -f "$NOTARY_ERR"
  echo "공증 프로필: $PROFILE 유효"
fi

if [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
  echo "경고: 커밋하지 않은 변경이 있는 채로 빌드합니다."
fi
echo "커밋: $(git rev-parse --short HEAD 2>/dev/null || echo unknown) / 버전 $VERSION ($BUILD) / 출력 $RUN_DIR"

rm -rf "$RUN_DIR"
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------- 아카이브
step "아카이브 (Release, generic/platform=macOS) — 로그: $LOG_DIR/archive.log"
# 버전 · 빌드 번호는 project.yml의 MARKETING_VERSION · CURRENT_PROJECT_VERSION 이름 그대로 덮어쓴다.
run_logged "$LOG_DIR/archive.log" \
  xcodebuild archive \
    -project apple/Taskforce.xcodeproj \
    -scheme Taskforce \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD"
echo "아카이브 완료: $ARCHIVE"

# ---------------------------------------------------------------- Developer ID 내보내기
step "Developer ID 내보내기 — 로그: $LOG_DIR/export.log"
run_logged "$LOG_DIR/export.log" \
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -allowProvisioningUpdates
[[ -d "$APP" ]] || fail "내보낸 앱이 없습니다: $APP (로그 $LOG_DIR/export.log)"
echo "내보내기 완료: $APP"

# ---------------------------------------------------------------- 검증
step "서명 · 권한 · 프로필 · 설정 확인"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "codesign --verify: 통과"

ENTITLEMENTS="$RUN_DIR/entitlements.plist"
codesign -d --entitlements :- "$APP" 2>/dev/null >"$ENTITLEMENTS"
echo "권한(entitlement) 키:"
plutil -p "$ENTITLEMENTS" | sed -nE 's/^  "([^"]+)" =>.*/  \1/p'
APS_ENV="$(plutil -p "$ENTITLEMENTS" | sed -nE 's/^  "com\.apple\.developer\.aps-environment" => "([^"]*)".*/\1/p')"
echo "aps-environment: ${APS_ENV:-(없음)}"
[[ "$APS_ENV" == "production" ]] || fail "aps-environment가 production이 아닙니다 (배포 빌드는 운영 APNs여야 알림이 옵니다)"

PROFILE_FILE="$APP/Contents/embedded.provisionprofile"
[[ -f "$PROFILE_FILE" ]] || fail "$PROFILE_FILE 이 없습니다. 제한된 권한(App Group · Apple 로그인 · 알림)은 프로필이 없으면 앱이 실행되지 않습니다"
PROFILE_PLIST="$RUN_DIR/embedded-profile.plist"
security cms -D -i "$PROFILE_FILE" >"$PROFILE_PLIST"
echo "프로필: Name=$(plutil -extract Name raw -o - "$PROFILE_PLIST")" \
     "TeamIdentifier=$(plutil -extract TeamIdentifier.0 raw -o - "$PROFILE_PLIST")" \
     "ExpirationDate=$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST")"

INFO="$APP/Contents/Info.plist"
plist_value() { plutil -extract "$1" raw -o - "$INFO" 2>/dev/null || true; }
host_of() { local rest="${1#*://}"; printf '%s' "${rest%%[/:?]*}"; }
API_HOST="$(host_of "$(plist_value APIBaseURL)")"
SUPABASE_HOST="$(host_of "$(plist_value SupabaseURL)")"
echo "버전: $(plist_value CFBundleShortVersionString) ($(plist_value CFBundleVersion))"
echo "APIBaseURL 호스트: ${API_HOST:-(비어 있음)}"
echo "SupabaseURL 호스트: ${SUPABASE_HOST:-(비어 있음)}"
[[ "$(plist_value CFBundleShortVersionString)" == "$VERSION" && "$(plist_value CFBundleVersion)" == "$BUILD" ]] \
  || fail "앱 Info.plist의 버전 · 빌드 번호가 요청과 다릅니다"
[[ "$API_HOST" == "$PROD_API_HOST" ]] || fail "APIBaseURL이 운영 주소($PROD_API_HOST)가 아닙니다"
[[ -n "$SUPABASE_HOST" ]] || fail "SupabaseURL이 비어 있습니다 (apple/Config/Secrets.xcconfig 확인)"
[[ -n "$(plist_value SupabaseKey)" ]] || fail "SupabaseKey가 비어 있습니다 (apple/Config/Secrets.xcconfig 확인)"
[[ -n "$(plist_value GIDClientID)" ]] || fail "GIDClientID가 비어 있습니다 (Google 로그인 버튼이 사라집니다)"
echo "Info.plist 확인: 통과 (키 값은 출력하지 않음)"

# ---------------------------------------------------------------- 앱 공증
if (( SKIP_NOTARIZE )); then
  step "앱 공증 · 스테이플: 건너뜀 (--skip-notarize)"
else
  step "앱 공증"
  APP_ZIP="$RUN_DIR/Taskforce-notarize.zip"
  ditto -c -k --keepParent "$APP" "$APP_ZIP"
  notarize "$APP_ZIP" app
  rm -f "$APP_ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# ---------------------------------------------------------------- DMG
step "DMG 만들기"
STAGE="$RUN_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Taskforce.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Taskforce" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >"$LOG_DIR/hdiutil.log" 2>&1 \
  || { cat "$LOG_DIR/hdiutil.log" >&2; fail "hdiutil create 실패"; }
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY_HASH" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG"
echo "DMG 서명 완료: $DMG"

if (( SKIP_NOTARIZE )); then
  step "DMG 공증 · 스테이플: 건너뜀 (--skip-notarize)"
else
  step "DMG 공증"
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

# ---------------------------------------------------------------- Gatekeeper
step "Gatekeeper 확인 (spctl)"
if (( SKIP_NOTARIZE )); then
  echo "(공증을 건너뛰어서 rejected / Unnotarized Developer ID 가 정상입니다. 참고용 출력)"
  spctl -a -vv "$APP" 2>&1 || true
  spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 || true
else
  spctl -a -vv "$APP" 2>&1
  spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1
fi

# ---------------------------------------------------------------- 결과
step "결과"
if (( SKIP_NOTARIZE )); then
  echo "공증하지 않은 시험 빌드입니다. 배포하지 마세요."
fi
echo "앱:   $APP"
echo "DMG:  $DMG"
echo "크기: $(du -h "$DMG" | awk '{ print $1 }')"
echo "SHA-256: $(shasum -a 256 "$DMG" | awk '{ print $1 }')"
