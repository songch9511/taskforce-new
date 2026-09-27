# 2단계 연동: 개인정보 처리방침에 넣을 문안

관련 문서: [처리방침(한)](privacy.ko.md) · [처리방침(영)](privacy.en.md) · [go live](../GO_LIVE.md) 8장 · [INTEGRATIONS](../INTEGRATIONS.md)

2단계 연동(Microsoft 365 · Zoom · GitHub · Linear · Jira)은 go live 때 연결 화면에 "Want this"로만 보이고 연결은 안 된다. 연동을 붙이는 PR에서 아래 절을 처리방침 3장에 넣는다.
**붙이기 전에는 처리방침에 넣지 않는다.** 붙지 않은 연동을 적으면 방침이 사실과 달라진다(BRAND.md "쓰지 않는 표현").

## 붙일 때마다 할 일

1. 아래 절의 `{{…}}`를 구현과 맞춘다. 읽는 범위 · 저장하는 것 · 권한 이름은 **코드가 실제로 요청하는 값**으로 적는다.
2. 처리방침 3장에 한국어 · 영어 절을 함께 넣고, 1장 표의 "연결한 서비스의 원문" 설명에 원문 종류를 더한다.
3. 11장 "서비스 연결 끊기" 줄에 그 서비스의 권한 해제 위치를 더한다.
4. 새 외부 처리자(AI · 호스팅 · 메일 발송 등)가 생기지 않는지 확인한다. 연결한 서비스 자체는 원문을 **받아 오는 곳**이라 7장 국외 이전 표에 넣지 않는다. 새 처리자가 생기면 7장 두 표를 함께 고친다.
5. 17장에 따라 시행 7일 전에 알린다. 수집 항목이 늘어나는 변경이므로 **30일 전 고지 대상인지** 먼저 판단한다(새 연동은 이용자가 직접 연결해야 처리가 시작되므로 7일 고지 + 연결 화면 안내로 충분하다고 본다. 법률 검토 때 함께 확인).
6. 앱 연결 화면에서 "Want this"를 연결 버튼으로 바꾸기 전에, 그 서비스의 원문 종류 골든셋과 eval을 돌린다(GO_LIVE.md "1단계 연동마다 go live 전에 끝낼 것"과 같은 기준).

---

## Microsoft 365 (Outlook 메일 · 일정 · Teams)

붙이기 전 확인:
- Microsoft Entra ID에 다중 테넌트 앱 등록. **게시자 확인(publisher verification)**: 새 테넌트는 기본값이 "확인된 게시자의 앱에만 사용자 동의 허용"이라, 확인하지 않으면 대부분의 회사 계정이 연결하지 못한다. Microsoft AI Cloud Partner Program 계정이 필요하다.
- 권한 후보(위임): `User.Read`, `offline_access`, `Mail.Read`, `Calendars.Read`, `Chat.Read`, `OnlineMeetingTranscript.Read.All`. 회의 전사 권한은 **관리자 동의가 필요**하다. Teams 채널 메시지까지 읽을지 정한다(`ChannelMessage.Read.All`은 관리자 동의 필요).
- Microsoft APIs 이용 약관 · Graph 데이터 사용 조건(AI 학습 · 보관 제한)을 붙일 때 최신 문서로 확인한다.

### 한국어

```markdown
### Microsoft 365 (Outlook · 일정 · Teams)

- **읽는 것:** Outlook 메일 스레드의 제목, 보낸 사람 · 받는 사람 · 참조(이름 · 이메일), 날짜, 본문 / 일정의 제목, 시작 · 종료 시각, 주최자와 참석자(이름 · 이메일), Teams 회의 식별자 / Teams 채팅(1:1 · 그룹) 메시지 중 이용자와의 대화, 이용자를 언급한 메시지, 이용자가 쓴 메시지 / Teams 회의 전사(발화자 이름, 발언, 시각). 뉴스레터 · 자동 알림 메일은 거르고 저장하지 않습니다. 첨부 파일은 읽지 않습니다.
- **일정의 쓰임:** Google Calendar와 같이, 같은 시각의 회의 원문에 참석자를 붙이는 데 씁니다.
- **저장하는 것:** 거르고 남은 메일 스레드 · 채팅 대화 · 회의 전사의 본문, 제목, 관련자, 날짜, 원본 링크. Microsoft 계정(테넌트) 식별자와 이름.
- **권한:** {{코드가 요청하는 권한 목록}}. 회의 전사 권한은 소속 조직 관리자의 승인이 필요할 수 있습니다. 메일을 보내거나 일정 · 메시지를 고치지 않습니다.
- **연결 끊기:** 앱의 연결 화면, 또는 myapps.microsoft.com / 조직 관리자.
```

### English

```markdown
### Microsoft 365 (Outlook, Calendar, Teams)

- **What we read:** Outlook email threads (subject; sender, recipients, and CC with names and email addresses; date; body); calendar events (title, start and end times, organizer and attendees with names and email addresses, Teams meeting identifier); Teams chat messages (1:1 and group) that are conversations with you, mention you, or were written by you; Teams meeting transcripts (speaker name, what was said, time). We filter out newsletters and automated notifications and do not store them. We do not read attachments.
- **How calendar events are used:** as with Google Calendar, to attach attendees to meeting sources from the same time.
- **What we store:** the body, subject, people involved, date, and original link of the remaining email threads, chat conversations, and meeting transcripts. Your Microsoft account (tenant) identifier and name.
- **Access:** {{permissions the code requests}}. Meeting transcript access may require approval from your organization's administrator. We never send email or change events or messages.
- **Disconnect:** in the app's Connections screen, or at myapps.microsoft.com or through your organization's administrator.
```

---

## Zoom (클라우드 녹화 전사)

붙이기 전 확인:
- Zoom App Marketplace의 General app(사용자 단위 OAuth). 다른 계정이 설치하려면 Marketplace 게시(심사)가 필요한지, 비공개 배포 한도가 있는지 확인한다.
- 권한 후보: 클라우드 녹화 목록 · 녹화 파일 읽기(세분화 권한 이름, 예: `cloud_recording:read:list_user_recordings`, `cloud_recording:read:recording`). 붙일 때 최신 이름으로 확정한다.
- 전사는 Zoom 유료 계정 + "오디오 전사" 설정을 켠 회의에만 생긴다. 전사 파일(VTT)에는 발화자 이름이 있다.
- Zoom API 이용 약관의 데이터 보관 · AI 학습 조건과, 앱 삭제(deauthorization) 이벤트를 받으면 데이터를 지워야 하는지 확인한다.

### 한국어

```markdown
### Zoom (클라우드 녹화 전사)

- **읽는 것:** 이용자 Zoom 계정의 클라우드 녹화 목록과 오디오 전사(발화자 이름, 발언, 시각), 회의 제목 · 시각 · 참가자 이름. 영상 · 음성 파일은 내려받지 않습니다.
- **저장하는 것:** 발화자 이름이 붙은 전사 본문, 회의 제목 · 시각, 참가자. Zoom 계정 식별자와 이름.
- **권한:** {{코드가 요청하는 권한 목록}}. 녹화 · 회의를 만들거나 지우지 않습니다.
- **연결 끊기:** 앱의 연결 화면, 또는 Zoom App Marketplace → 관리 → 설치한 앱. Zoom에서 앱을 삭제하면 {{Zoom 약관에 맞춘 처리: 예) 그 연결로 가져온 데이터를 N일 안에 지웁니다}}.
```

### English

```markdown
### Zoom (cloud recording transcripts)

- **What we read:** the list of cloud recordings in your Zoom account and their audio transcripts (speaker name, what was said, time), plus meeting title, time, and participant names. We do not download video or audio files.
- **What we store:** the transcript text with speaker names, meeting title and time, participants. Your Zoom account identifier and name.
- **Access:** {{permissions the code requests}}. We never create or delete recordings or meetings.
- **Disconnect:** in the app's Connections screen, or in Zoom App Marketplace → Manage → Installed Apps. If you remove the app in Zoom, {{handling required by Zoom's terms, e.g. we delete data imported through that connection within N days}}.
```

---

## GitHub (배정된 이슈 · 리뷰 요청 · 언급)

붙이기 전 확인:
- OAuth App보다 **GitHub App**을 권장한다(저장소 단위로 고르고 권한이 세분화된다). 권한 후보: Issues 읽기, Pull requests 읽기, Metadata 읽기. 알림 API로 언급을 받을지, 이벤트(webhook)로 받을지 정한다.
- 배정 · 리뷰 요청은 구조화된 할 일 형태(INTEGRATIONS.md "입력은 두 가지 형태")로 처리하므로 LLM으로 보내지 않는다. 언급 댓글만 글 원문으로 보낼지 정하고, 문안의 "외부 AI" 문장을 맞춘다.

### 한국어

```markdown
### GitHub

- **읽는 것:** 이용자가 GitHub App 설치 때 고른 저장소에서, 이용자에게 배정된 이슈 · 풀 리퀘스트, 이용자에게 온 리뷰 요청, 이용자를 언급한 댓글(제목, 본문, 작성자, 상태, 시각, 링크). 코드와 파일 내용은 읽지 않습니다.
- **처리 방식:** 배정 · 리뷰 요청 · 상태 변화는 AI 없이 그대로 할 일로 옮깁니다. {{언급 댓글은 할 일을 찾기 위해 외부 AI로 보냅니다(4장) / 보내지 않습니다}}.
- **저장하는 것:** 위 항목의 제목 · 본문 · 작성자 · 상태 · 링크. GitHub 계정 식별자와 이름.
- **권한:** {{GitHub App 권한 목록}}. 이슈 · 코드 · 댓글을 쓰거나 고치지 않습니다.
- **연결 끊기:** 앱의 연결 화면, 또는 GitHub → Settings → Applications.
```

### English

```markdown
### GitHub

- **What we read:** in the repositories you select when installing the GitHub App: issues and pull requests assigned to you, review requests sent to you, and comments that mention you (title, body, author, state, time, link). We do not read code or file contents.
- **How it is processed:** assignments, review requests, and state changes become tasks directly, without AI. {{Comments that mention you are sent to external AI to find tasks (section 4) / are not sent to external AI}}.
- **What we store:** the title, body, author, state, and link of the items above. Your GitHub account identifier and name.
- **Access:** {{GitHub App permissions}}. We never write or change issues, code, or comments.
- **Disconnect:** in the app's Connections screen, or in GitHub → Settings → Applications.
```

---

## Linear (배정된 이슈 · 언급)

붙이기 전 확인:
- Linear OAuth 앱, 권한은 `read`만. 웹훅으로 변경을 받을지, 주기 조회로 받을지 정한다.
- 배정 · 상태 · 기한은 구조화된 할 일로 처리한다(LLM 없음). 댓글 언급을 글 원문으로 보낼지 정한다.

### 한국어

```markdown
### Linear

- **읽는 것:** 이용자에게 배정된 이슈의 제목, 설명, 상태, 기한, 우선순위, 팀 · 프로젝트 이름, 링크와 이용자를 언급한 댓글(본문, 작성자, 시각).
- **처리 방식:** 배정 · 상태 · 기한은 AI 없이 그대로 할 일로 옮깁니다. {{언급 댓글은 외부 AI로 보냅니다(4장) / 보내지 않습니다}}.
- **저장하는 것:** 위 항목. Linear 워크스페이스 식별자와 이름.
- **권한:** `read`. 이슈를 만들거나 고치지 않습니다.
- **연결 끊기:** 앱의 연결 화면, 또는 Linear → Settings → Account → Security & access(승인한 앱).
```

### English

```markdown
### Linear

- **What we read:** issues assigned to you (title, description, state, due date, priority, team and project name, link) and comments that mention you (body, author, time).
- **How it is processed:** assignments, states, and due dates become tasks directly, without AI. {{Comments that mention you are sent to external AI (section 4) / are not sent to external AI}}.
- **What we store:** the items above. Your Linear workspace identifier and name.
- **Access:** `read`. We never create or change issues.
- **Disconnect:** in the app's Connections screen, or in Linear → Settings → Account → Security & access (authorized applications).
```

---

## Jira (배정된 이슈 · 언급)

붙이기 전 확인:
- Atlassian OAuth 2.0 (3LO) 앱. 권한 후보: `read:jira-work`, `read:jira-user`, `offline_access`. 다른 사이트에 배포하려면 개발자 콘솔에서 배포(Distribution)를 켜고 **개인정보 신고(personal data declaration)**를 해야 한다.
- Atlassian은 사용자 계정이 지워지면 앱이 보관한 개인정보를 지우도록 요구한다(Personal data reporting API). 주기 보고를 구현할지 붙일 때 확인한다.

### 한국어

```markdown
### Jira

- **읽는 것:** 이용자가 연결한 Jira 사이트에서 이용자에게 배정된 이슈의 요약, 설명, 상태, 기한, 프로젝트 이름, 링크와 이용자를 언급한 댓글(본문, 작성자, 시각).
- **처리 방식:** 배정 · 상태 · 기한은 AI 없이 그대로 할 일로 옮깁니다. {{언급 댓글은 외부 AI로 보냅니다(4장) / 보내지 않습니다}}.
- **저장하는 것:** 위 항목. Jira 사이트 식별자와 이름, Atlassian 계정 식별자.
- **권한:** {{코드가 요청하는 권한 목록}}. 이슈를 만들거나 고치지 않습니다.
- **Atlassian 계정 삭제:** Atlassian이 계정 삭제를 알리면 그 계정과 관련해 보관한 개인정보를 {{기간}} 안에 지웁니다.
- **연결 끊기:** 앱의 연결 화면, 또는 Atlassian 계정 → 보안 → 연결된 앱.
```

### English

```markdown
### Jira

- **What we read:** on the Jira site you connect, issues assigned to you (summary, description, state, due date, project name, link) and comments that mention you (body, author, time).
- **How it is processed:** assignments, states, and due dates become tasks directly, without AI. {{Comments that mention you are sent to external AI (section 4) / are not sent to external AI}}.
- **What we store:** the items above. Your Jira site identifier and name, and your Atlassian account identifier.
- **Access:** {{permissions the code requests}}. We never create or change issues.
- **Atlassian account deletion:** when Atlassian notifies us that an account was deleted, we delete personal information we hold about that account within {{period}}.
- **Disconnect:** in the app's Connections screen, or in your Atlassian account → Security → Connected apps.
```
