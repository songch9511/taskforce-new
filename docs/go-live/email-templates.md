# 로그인 코드 메일 · 메일 설정 (Supabase + Resend)

이메일 로그인은 **6자리 코드**다 (OA 이메일 로그인 계약, 앱은 `SessionStore.sendEmailCode` · `verifyEmailCode`, 웹 `/login`은 `sendCode` · `verifyCode`).
Supabase가 코드를 만들어 메일로 보내고, 메일 발송은 Resend SMTP를 쓴다. 이 문서는 **사용자가 Supabase 대시보드에 붙여 넣는 값**의 원본이다.
비밀 값(Resend API 키)은 이 저장소에 두지 않는다: 비밀번호 관리자와 Supabase SMTP 칸에만 있다.

> 메일 문구(제목 · 본문)는 계약 7.2 초안이다. 앱 화면 문구와 달리 따로 승인 표에 없으므로 바꾸면 이 문서를 고치고 아래 시험이 같은 모양을 본다.

## 1. 템플릿 (Authentication → Emails → Templates)

**Magic Link**와 **Confirm signup** 둘 다 같은 제목 · 같은 본문을 붙인다. 처음 보는 주소는 Confirm signup 템플릿을 받고, 이미 있는 주소는 Magic Link 템플릿을 받는다 (Supabase 동작. 실제로 그런지는 작성 첫날 로컬 GoTrue로 확인했다: 노트 참고).

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
| Authentication → Sign In / Providers → Email | Confirm email | **켬** (꺼져 있으면 코드를 보낼 때 이미 확인된 계정이 된다) |
| 〃 | Email OTP Expiration | `600` (초 = 10분) |
| 〃 | Email OTP Length | `6` (대시보드 자리 이름은 확인 필요. 기본이 8인 프로젝트가 있다) |
| Authentication → Rate Limits | Rate limit for sending emails | **시간당 30통** |
| 〃 | 나머지 (보내기 · 확인 IP별 5분 30, 다시 받기 60초) | 기본 그대로 |
| Authentication → Hooks | Before User Created | `public.hook_before_user_created` (켜져 있는지 본다. 함수 이름이 그대로라 마이그레이션 뒤 바꿀 것이 없다) |
| Authentication → Attack Protection | CAPTCHA | 켜지 않는다 (미확인 가입이 하루 500을 넘거나 Resend 반송 · 신고 경고가 오면 별도 작업) |

Resend 쪽: 도메인 `mail.taskforcelabs.dev`, 발송 지역 도쿄(`ap-northeast-1`, 나중에 바꾸려면 도메인을 지우고 DNS를 다시 넣어야 한다), 열기 · 클릭 추적 끔, API 키는 보내기 권한만 + 이 도메인만.

## 3. 운영 메모: Resend 무료 요금제의 하루 상한

- 처음에는 Resend **무료 요금제**로 시작한다: **하루 100통**, 한 달 3,000통. Supabase 메일 발송 한도를 시간당 30통으로 둔 것은 하루 상한에 빨리 닿지 않게 하려는 것이다.
- 하루 상한에 닿으면 Resend가 보내기를 거절하고, 앱은 보내기 실패 · 한도 · 확인 한도 · 다시 받기 실패를 합친 한 줄 "Couldn't continue. Try again in a few minutes."를 칸 아래 회색으로 보인다(사용자 승인 2026-10-20). Supabase가 이 거절을 어떤 상태로 돌려주는지는 처음 닿는 날 확인한다(429가 아니어도 같은 한 줄이다).
- **하루 상한에 닿으면 Pro로 올린다** (Resend Settings → Billing → Pro, $20/월, 월 5만 통). 쓰는 양을 보고 사용자가 올린다. 주 1회 Resend 대시보드의 보낸 수 · 반송 · 신고를 본다.
- 본문 보관 끄기(월 $50 추가)는 여는 날 조건이 아니다 (본문은 10분 뒤 효력 없는 코드뿐).

## 4. 시험 메일 확인 (여는 날 전, 사용자)

1. 웹 `/login`(코드 PR 배포 뒤)으로 운영자 주소에 코드를 받아 본다.
2. 메일 헤더: `spf=pass` · `dkim=pass` · `dmarc=pass`(또는 DMARC 없음), 보낸 사람 `Taskforce <signin@mail.taskforcelabs.dev>`.
3. Resend 대시보드 Emails에 한 줄이 생겼는지, 받은 시각이 몇 초인지.
4. 본문에 링크 · 이미지가 없고 코드 6자리만 있는지.
