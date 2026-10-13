#!/usr/bin/env bash
# Mac 앱 DMG 배포: 아카이브 → Developer ID 내보내기 → 공증 · 스테이플 → DMG → 서명 · 공증 · 스테이플 → Gatekeeper 확인.
# 저장소 맨 위에서 실행한다. 절차 · 일회성 준비(공증 프로필)는 docs/go-live/mac-dmg.md.
#
#   scripts/release-mac-dmg.sh --version 0.1.0 --build 2 [--profile taskforce-notary] [--out <directory>] [--skip-notarize] [--appcast-dir <directory>] [--download-url-prefix <url>]
# --out 기본값: ${TMPDIR:-/tmp}/taskforce-release (저장소 밖 임시 폴더).
# --skip-notarize: 공증 · 스테이플을 건너뛰는 시험용. 만든 DMG는 배포하면 안 된다(Gatekeeper가 막는다).
# --appcast-dir: 공증 뒤 선택 단계(Sparkle appcast)가 DMG 사본과 appcast.xml을 둘 로컬 폴더. 기본값: <출력>/<이름>/appcast. 올리지는 않는다.
# --download-url-prefix: appcast 안 DMG 주소의 접두어. 기본값: 앱 SUFeedURL의 폴더.
# appcast 단계는 앱의 SUFeedURL · SUPublicEDKey, Keychain의 Sparkle 서명 키, generate_appcast(환경 변수 SPARKLE_BIN_DIR)가 모두 있을 때만 돈다. 없으면 건너뛴다(docs/go-live/mac-dmg.md "자동 업데이트").
set -euo pipefail

TEAM_ID="${TEAM_ID:-U9DWQKQFMW}"
PROD_API_HOST="api.taskforcelabs.dev"
EXPORT_OPTIONS="apple/Config/ExportOptions-DeveloperID.plist"

VERSION=""
BUILD=""
PROFILE="taskforce-notary"
OUT="${TMPDIR:-/tmp}/taskforce-release"
SKIP_NOTARIZE=0
APPCAST_DIR=""
DOWNLOAD_URL_PREFIX=""

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
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
    --appcast-dir) [[ $# -ge 2 ]] || fail "--appcast-dir 값이 없습니다"; APPCAST_DIR="$2"; shift 2 ;;
    --download-url-prefix) [[ $# -ge 2 ]] || fail "--download-url-prefix 값이 없습니다"; DOWNLOAD_URL_PREFIX="$2"; shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage >&2; fail "모르는 인자: $1" ;;
  esac
done

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { usage >&2; fail "--version은 0.1.0 같은 형식이어야 합니다"; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { usage >&2; fail "--build는 정수여야 합니다"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ "$OUT" = /* ]] || OUT="$ROOT/$OUT"
[[ -z "$APPCAST_DIR" || "$APPCAST_DIR" = /* ]] || APPCAST_DIR="$ROOT/$APPCAST_DIR"

NAME="Taskforce-$VERSION-$BUILD"
RUN_DIR="$OUT/$NAME"
LOG_DIR="$RUN_DIR/logs"
ARCHIVE="$RUN_DIR/Taskforce.xcarchive"
DERIVED="$RUN_DIR/DerivedData"
EXPORT_DIR="$RUN_DIR/export"
APP="$EXPORT_DIR/Taskforce.app"
DMG="$RUN_DIR/$NAME.dmg"
APPCAST_DIR="${APPCAST_DIR:-$RUN_DIR/appcast}"

# Preserve an earlier artifact or log set when the same version/build is retried.
if [[ -e "$RUN_DIR" || -L "$RUN_DIR" ]]; then
  fail "출력 경로가 이미 있습니다. 기존 산출물을 보존했으니 새 --build 값을 쓰세요: $RUN_DIR"
fi

# 원본 로그는 로컬에만 보관하고, 실패하면 단계와 로그 경로만 보여 준다.
run_logged() {
  local phase="$1" log="$2"; shift 2
  if ! "$@" >"$log" 2>&1; then
    printf '\n실패 단계: %s\n로그: %s\n' "$phase" "$log" >&2
    exit 1
  fi
}

# 공증 제출 → Accepted가 아니면 상세 로그도 로컬에 저장하고 멈춘다. 인자: 파일, 라벨
notarize() {
  local file="$1" label="$2" id
  local out="$LOG_DIR/notary-$label.txt" detail="$LOG_DIR/notary-$label-detail.txt"
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait >"$out" 2>&1 || true
  if ! grep -q '^ *status: Accepted$' "$out"; then
    id="$(awk '$1 == "id:" { print $2; exit }' "$out")"
    printf '\n실패 단계: 공증 (%s)\n로그: %s\n' "$label" "$out" >&2
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" --keychain-profile "$PROFILE" >"$detail" 2>&1 || true
      printf '상세 로그: %s\n' "$detail" >&2
    fi
    exit 1
  fi
}

# 샌드박스 끔 (DEC-1 A, docs/go-live/mac-dmg.md): 서명된 앱의 권한에 App Sandbox가 있으면 멈춘다.
# 샌드박스 앱이 띄운 자식 프로세스는 샌드박스를 물려받아 사용자의 claude · codex 로그인과 PATH에 닿지 못한다. 인자: codesign -d --entitlements 출력(plist) 파일
reject_sandbox_entitlement() {
  local keys
  keys="$(plutil -p "$1" 2>/dev/null)" || fail "서명된 앱의 권한(entitlement)을 읽을 수 없습니다: $1"
  if grep -q '"com\.apple\.security\.app-sandbox"' <<<"$keys"; then
    fail "서명된 앱에 App Sandbox 권한(com.apple.security.app-sandbox)이 있습니다. apple/Taskforce/Taskforce-macOS.entitlements와 빌드 설정 ENABLE_APP_SANDBOX를 확인하세요"
  fi
}

# 선택 단계 (공증 뒤): Sparkle appcast를 **로컬 폴더에만** 만든다. 업로드 · 게시는 하지 않는다 (호스팅 위치는 사용자가 정한다, docs/go-live/mac-dmg.md "자동 업데이트").
# EdDSA 개인 키는 이 스크립트가 읽거나 출력하지 않는다: generate_appcast가 사용자 Keychain에서 직접 읽는다.
# 여기서는 그 항목이 있는지만 속성으로 확인한다 (-g · -w 없음, 출력 버림). 항목이 없을 때 도구를 부르면 서명하지 못해 실패하기 때문이다(Sparkle 2.10.0 확인).
# 피드 · 공개 키 · 도구 · Keychain 키 중 하나라도 없으면 건너뛴다(실패 아님). 도구가 실패하면 멈춘다.
# 다운로드 URL 접두어는 끝에 "/"가 있어야 파일이 그 폴더 아래로 풀린다(없으면 붙인다: 도구가 RFC 3986 상대 주소로 이어 붙인다).
# 인자: DMG, appcast 폴더, SUFeedURL, SUPublicEDKey, 다운로드 URL 접두어, generate_appcast 경로, 로그 파일
make_appcast() {
  local dmg="$1" dir="$2" feed="$3" pubkey="$4" prefix="$5" tool="$6" log="$7"
  if [[ -z "$feed" ]]; then
    echo "appcast: 건너뜀 (앱 Info.plist의 SUFeedURL이 비어 있습니다. apple/Config/Release.xcconfig의 SPARKLE_FEED_URL)"; return 0
  fi
  if [[ -z "$pubkey" ]]; then
    echo "appcast: 건너뜀 (앱 Info.plist의 SUPublicEDKey가 비어 있습니다. apple/Config/Release.xcconfig의 SPARKLE_PUBLIC_ED_KEY)"; return 0
  fi
  if [[ ! -x "$tool" ]]; then
    echo "appcast: 건너뜀 (generate_appcast를 찾을 수 없습니다: $tool. 환경 변수 SPARKLE_BIN_DIR로 Sparkle bin 폴더를 알려 주세요)"; return 0
  fi
  if ! security find-generic-password -s "https://sparkle-project.org" -a "ed25519" >/dev/null 2>&1; then
    echo "appcast: 건너뜀 (로그인 Keychain에 Sparkle 서명 키가 없습니다. docs/go-live/mac-dmg.md \"자동 업데이트\" 1번)"; return 0
  fi
  prefix="${prefix%/}/"
  mkdir -p "$dir"
  ditto "$dmg" "$dir/$(basename "$dmg")"
  if ! "$tool" --download-url-prefix "$prefix" -o "$dir/appcast.xml" "$dir" >"$log" 2>&1; then
    printf '\n실패 단계: appcast 만들기\n로그: %s\n' "$log" >&2
    exit 1
  fi
  [[ -s "$dir/appcast.xml" ]] || fail "appcast.xml이 만들어지지 않았습니다 (로그 $log)"
  echo "appcast 완료 (업로드하지 않음): $dir/appcast.xml"
  echo "다운로드 주소 접두어: $prefix  (올리기 전에 appcast.xml의 enclosure url을 확인하세요)"
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
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >"$NOTARY_ERR" 2>&1; then
    printf '\n실패 단계: 공증 프로필 확인\n로그: %s\n' "$NOTARY_ERR" >&2
    exit 1
  fi
  rm -f "$NOTARY_ERR"
  echo "공증 프로필: $PROFILE 유효"
fi

[[ -z "$(git status --porcelain --untracked-files=all 2>/dev/null)" ]] \
  || fail "앱 source commit을 정확히 기록하려면 Git 작업 트리가 깨끗해야 합니다 (ignored Secrets.xcconfig은 제외됨)"
SOURCE_COMMIT="$(git rev-parse HEAD 2>/dev/null)" || fail "빌드 source commit을 읽을 수 없습니다"
BUILD_TIME_UTC="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "커밋: $(git rev-parse --short HEAD) / 버전 $VERSION ($BUILD) / 출력 $RUN_DIR"
echo "앱 빌드 정보: Beta / $SOURCE_COMMIT / $BUILD_TIME_UTC UTC"

mkdir -p "$OUT"
mkdir "$RUN_DIR" || fail "출력 경로를 만들 수 없습니다 (기존 경로는 보존됨): $RUN_DIR"
mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------- 아카이브
step "아카이브 (Release, generic/platform=macOS) — 로그: $LOG_DIR/archive.log"
# 버전 · 빌드 번호는 project.yml의 MARKETING_VERSION · CURRENT_PROJECT_VERSION 이름 그대로 덮어쓴다.
run_logged "아카이브" "$LOG_DIR/archive.log" \
  xcodebuild archive \
    -project apple/Taskforce.xcodeproj \
    -scheme Taskforce \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD" \
    TF_RELEASE_CHANNEL=Beta \
    TF_SOURCE_COMMIT="$SOURCE_COMMIT" \
    TF_BUILD_TIME_UTC="$BUILD_TIME_UTC"
echo "아카이브 완료: $ARCHIVE"

# ---------------------------------------------------------------- Developer ID 내보내기
step "Developer ID 내보내기 — 로그: $LOG_DIR/export.log"
run_logged "Developer ID 내보내기" "$LOG_DIR/export.log" \
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
reject_sandbox_entitlement "$ENTITLEMENTS"
echo "App Sandbox 권한: 없음"
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
echo "앱 빌드 정보: $(plist_value TaskforceReleaseChannel) / $(plist_value TaskforceSourceCommit) / $(plist_value TaskforceBuildTimeUTC) UTC"
echo "APIBaseURL 호스트: ${API_HOST:-(비어 있음)}"
echo "SupabaseURL 호스트: ${SUPABASE_HOST:-(비어 있음)}"
UPDATE_FEED_HOST="$(host_of "$(plist_value SUFeedURL)")"
echo "자동 업데이트(Sparkle): 피드 호스트 ${UPDATE_FEED_HOST:-(비어 있음)} / 공개 키 $([[ -n "$(plist_value SUPublicEDKey)" ]] && echo 설정됨 || echo 비어 있음) (둘 중 하나라도 비면 업데이터는 꺼진 채로 나갑니다)"
[[ "$(plist_value CFBundleShortVersionString)" == "$VERSION" && "$(plist_value CFBundleVersion)" == "$BUILD" ]] \
  || fail "앱 Info.plist의 버전 · 빌드 번호가 요청과 다릅니다"
[[ "$(plist_value TaskforceReleaseChannel)" == "Beta" ]] || fail "앱 Info.plist의 출시 채널이 Beta가 아닙니다"
[[ "$(plist_value TaskforceSourceCommit)" == "$SOURCE_COMMIT" ]] || fail "앱 Info.plist의 source commit이 아카이브와 다릅니다"
[[ "$(plist_value TaskforceBuildTimeUTC)" == "$BUILD_TIME_UTC" ]] || fail "앱 Info.plist의 UTC build time이 아카이브와 다릅니다"
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
  || fail "실패 단계: DMG 만들기 — 로그: $LOG_DIR/hdiutil.log"
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

# ---------------------------------------------------------------- Sparkle appcast (선택)
step "Sparkle appcast (선택, 로컬 폴더에만 만들고 올리지 않음)"
APPCAST_FEED="$(plist_value SUFeedURL)"
if (( SKIP_NOTARIZE )); then
  echo "appcast: 건너뜀 (--skip-notarize: 공증하지 않은 DMG는 업데이트로 배포하지 않습니다)"
else
  make_appcast "$DMG" "$APPCAST_DIR" "$APPCAST_FEED" "$(plist_value SUPublicEDKey)" "${DOWNLOAD_URL_PREFIX:-${APPCAST_FEED%/*}/}" "${SPARKLE_BIN_DIR:-$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin}/generate_appcast" "$LOG_DIR/appcast.log"
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
