# 로그인 코드 메일 · 메일 설정 (Supabase + Resend)

이메일 로그인은 **8자리 코드**다 (OA 이메일 로그인 계약, 앱은 `SessionStore.sendEmailCode` · `verifyEmailCode`, 웹 `/login`은 `sendCode` · `verifyCode`).
Supabase가 코드를 만들어 메일로 보내고, 메일 발송은 Resend SMTP를 쓴다. 이 문서는 **사용자가 Supabase 대시보드에 붙여 넣는 값**의 원본이다.
비밀 값(Resend API 키)은 이 저장소에 두지 않는다: 비밀번호 관리자와 Supabase SMTP 칸에만 있다.

> 메일 문구(제목 · 본문)는 계약 7.2 초안이다. 앱 화면 문구와 달리 따로 승인 표에 없으므로 바꾸면 이 문서를 고치고 아래 시험이 같은 모양을 본다.

## 1. 템플릿 (Authentication → Emails → Templates)

Supabase 이메일 템플릿 **여섯 개 모두**에 같은 제목 · 같은 본문을 붙인다: **Confirm signup** · **Magic Link** · **Invite user** · **Change Email Address** · **Reset Password** · **Reauthentication** (대시보드 이름은 처음 붙일 때 확인한다).

- 로그인 코드가 가는 곳은 둘이다: 처음 보는 주소는 Confirm signup 템플릿을 받고, 이미 있는 주소는 Magic Link 템플릿을 받는다 (Supabase 동작. 실제로 그런지는 작성 첫날 로컬 GoTrue로 확인했다: 노트 참고).
- 나머지 넷(Invite user · Change Email Address · Reset Password · Reauthentication)은 이 앱이 쓰지 않는 흐름이다. 그래도 같은 본문으로 바꾼다: 기본 템플릿에는 링크(`{{ .ConfirmationURL }}`)가 있고, 비밀번호 재설정 같은 일부는 공개 API로 누구나 아무 주소에 보낼 수 있어서 링크가 든 메일이 이 서비스 이름으로 나가지 않게 하려는 것이다. 이 코드로 앱에서 할 수 있는 일은 없다 (앱은 그 흐름을 쓰지 않는다). 제목 · 본문의 "sign-in" 문구가 그 흐름에는 맞지 않아도 링크가 없는 쪽이 안전하다고 보고 같은 문구를 쓴다.

- 제목: `Your Taskforce sign-in code` (코드를 제목에 넣지 않는다: 잠금 화면 · 알림 미리보기에 코드가 보이지 않게)
- 본문: 아래 HTML. 코드(`{{ .Token }}`)만 있다. **링크 · 이미지 · 추적 픽셀이 없다** (`{{ .ConfirmationURL }}`을 쓰지 않는다: 메일 검사기가 링크를 먼저 열어 버리는 문제를 피하고, 앱 사용자의 메일에 웹 로그인 길이 생기지 않게 한다).
- Supabase 대시보드에는 HTML 본문 칸 하나뿐이다. 글자판은 같은 말의 참고본이다.

```html
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="supported-color-schemes" content="light dark">
<style>
  body { margin: 0; padding: 24px 16px; background: #ffffff; color: #1f1f1f; font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", Arial, sans-serif; }
  .code { margin: 16px 0; font: 600 32px/1.2 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; letter-spacing: 6px; }
  .note { color: #5f6368; font-size: 13px; }
  @media (prefers-color-scheme: dark) {
    body { background: #1c1c1e; color: #f2f2f7; }
    .note { color: #a1a1a6; }
  }
</style>
</head>
<body>
<p>Your Taskforce sign-in code is:</p>
<p class="code">{{ .Token }}</p>
<p class="note">It expires in 10 minutes. If you didn't ask for it, you can ignore this email.</p>
</body>
</html>
```

```text
Your Taskforce sign-in code is:

{{ .Token }}

It expires in 10 minutes. If you didn't ask for it, you can ignore this email.
```

**바꾸는 날**: 웹 `/login` 코드 PR(`sendCode` · `verifyCode`)이 배포된 날이다. 템플릿에서 링크를 빼면 옛 웹 링크 로그인이 사라지기 때문이다. `/auth/confirm`은 그대로 둔다 (이미 보낸 옛 메일의 링크용).

## 2. Supabase 설정 (운영 대시보드, 사용자)

| 위치 | 칸 | 값 |
|---|---|---|
| Authentication → Emails → SMTP Settings | Sender email | `signin@mail.taskforcelabs.dev` |
| 〃 | Sender name | `Taskforce` |
| 〃 | Host · Port | `smtp.resend.com` · `465` |
| 〃 | Username · Password | `resend` · Resend API 키(`re_…`, 비밀번호 관리자에서 붙여 넣음) |
| Authentication → Sign In / Providers → Email | Confirm email | **켬 (보안 필수)**. 꺼져 있으면 코드를 보낼 때 이미 확인된 계정이 되어, 가입 전 비밀번호 탈취를 막는 전제(확인 전 사용자는 로그인할 수 없다)와 미확인 가입 정리가 모두 무너진다. 여는 날 전에 켜져 있는지 본다 |
| 〃 | Email OTP Expiration | `600` (초 = 10분) |
| 〃 | Email OTP Length | `8` (사용자 결정 2026-10-20. 대시보드 자리 이름은 확인 필요. 앱 · 웹의 코드 칸이 8자리를 기다리므로 다른 값이면 로그인이 안 된다) |
| Authentication → Rate Limits | Rate limit for sending emails | **시간당 30통** |
| 〃 | 나머지 (보내기 · 확인 IP별 5분 30, 다시 받기 60초) | 기본 그대로 |
| Authentication → Hooks | Before User Created | `public.hook_before_user_created` (켜져 있는지 본다. 함수 이름이 그대로라 마이그레이션 뒤 바꿀 것이 없다) |
| Authentication → Attack Protection | CAPTCHA | 처음에는 켜지 않는다. **Resend 하루 상한 도달 · 반송 2% 초과 · 시간당 429 관측** 중 하나가 보이면 켜는 별도 작업을 한다 (앱이 `captchaToken`을 보내야 하므로 앱 변경이 필요하다) |

Resend 쪽: 도메인 `mail.taskforcelabs.dev`, 발송 지역 도쿄(`ap-northeast-1`, 나중에 바꾸려면 도메인을 지우고 DNS를 다시 넣어야 한다), 열기 · 클릭 추적 끔, API 키는 보내기 권한만 + 이 도메인만.

## 3. 운영 메모: Resend 무료 요금제의 하루 상한

- 처음에는 Resend **무료 요금제**로 시작한다: **하루 100통**, 한 달 3,000통. Supabase 메일 발송 한도를 시간당 30통으로 둔 것은 하루 상한에 빨리 닿지 않게 하려는 것이다. 한 곳이 이 예산을 바닥내지 못하게 가입 훅도 지난 1시간 미확인 가입이 15를 넘으면 막는다 (20261201000000).
- 하루 상한에 닿으면 Resend가 보내기를 거절하고, 앱은 보내기 실패 · 한도 · 확인 한도 · 다시 받기 실패를 합친 한 줄 "Couldn't continue. Try again in a few minutes."를 칸 아래 회색으로 보인다(사용자 승인 2026-10-20). Supabase가 이 거절을 어떤 상태로 돌려주는지는 처음 닿는 날 확인한다(429가 아니어도 같은 한 줄이다).
- **하루 상한에 닿으면 Pro로 올린다** (Resend Settings → Billing → Pro, $20/월, 월 5만 통). 쓰는 양을 보고 사용자가 올린다. 주 1회 Resend 대시보드의 보낸 수 · 반송 · 신고를 본다.
- 본문 보관 끄기(월 $50 추가)는 여는 날 조건이 아니다 (본문은 10분 뒤 효력 없는 코드뿐).

## 4. 시험 메일 확인 (여는 날 전, 사용자)

1. 웹 `/login`(코드 PR 배포 뒤)으로 운영자 주소에 코드를 받아 본다.
2. 메일 헤더: `spf=pass` · `dkim=pass` · `dmarc=pass`(또는 DMARC 없음), 보낸 사람 `Taskforce <signin@mail.taskforcelabs.dev>`.
3. Resend 대시보드 Emails에 한 줄이 생겼는지, 받은 시각이 몇 초인지.
4. 본문에 링크 · 이미지가 없고 코드 8자리만 있는지.
