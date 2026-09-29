# Privacy Policy

Taskforce (AI project manager) · Beta

- Effective date: {{effective date — the day this is published, e.g. 2026-10-XX}}
- Version: Beta 1.0
- 한국어: [개인정보 처리방침](privacy.ko.md) (the Korean version prevails if the two differ)

태스크포스 ("we", "us") operates the Taskforce app (iOS and macOS), its server, and the website (www.taskforcelabs.dev). We process your personal information under the Personal Information Protection Act of the Republic of Korea (PIPA) and other applicable laws.
This policy explains what we process, why, where, and for how long, and how you can stop or delete that processing.

## At a glance

- Taskforce reads meeting notes, messages, and email from the services **you connect** (Notion, Google, Slack) and finds the work you committed to. We use your source text only for this.
- To find that work, we send source text to external AI models. **We do not send anything until you agree in the app.** AI requests go only to providers that keep no data (Zero Data Retention), and nothing is used to train any AI model.
- Your data is stored on servers and a database in Sydney, Australia. We keep no database backups, so **deleting your account deletes your stored data right away.**
- We read your source text **only when you ask us to, or while responding to a security incident.** If we want to look at a source to analyze an extraction error, we ask for your consent first.
- We do not sell your information or use it for advertising. The website has no analytics and no cookies.

## Contents

1. What we process and how we collect it
2. Purposes and legal grounds
3. What we do with each connected service
4. What we send to external AI
5. Retention and deletion
6. Disclosure to third parties
7. Processors and international transfers
8. When we look at your source text
9. Security measures
10. Cookies and similar technologies
11. Your rights and how to use them
12. Automated decisions
13. Privacy officer
14. Remedies in Korea
15. Google user data
16. Users in the EU and UK
17. Changes to this policy

---

## 1. What we process and how we collect it

| Category | Items | How we collect it |
|---|---|---|
| Account | Sign in with Apple: your Apple user identifier and email address (if you choose "Hide My Email", the relay address Apple creates). Email sign-in: your email address. We do not receive your name from Apple | When you sign in |
| Profile | Display name, aliases, additional email addresses | You enter them in the app |
| Connections | The connected service, workspace or account identifier and name, connection settings (names and identifiers of databases to include or skip), sync status, access tokens (stored encrypted) | When you connect a service in the app |
| Source text from connected services | Meeting notes, documents, task database entries, calendar events, meeting transcripts, email threads, and Slack messages, with their titles, times, original links, and the people involved (names and email addresses of senders, recipients, attendees, and speakers). See section 3 for each service | Through the connected service's API |
| Information derived from source text | Task title, scope, due date, owner, counterpart name, evidence quotes, a record of who said what and when, change history, AI judgment records (candidates and probabilities), numeric vectors used to find similar tasks (embeddings) | When the server processes a source |
| Usage records | App opens; starting, completing, editing, deleting, or confirming a task; use of "Hand off to AI"; weekly question answers; times you reported a missing task; requests for services we do not support yet | When you use the app |
| Device and notifications | Push notification device token (APNs), platform (iOS or macOS), app version, last seen time | After the app receives notification permission |
| Automatically generated | IP address and device information (User-Agent) of your sign-in session; server request records (path, time, status code, short error message) | Generated while you use the service |
| Support | Your email address and message | When you email us |

- We do not ask for national identification numbers or sensitive information. If your connected notes, messages, or email contain such information, we do not separate it out; it is processed the same way as the rest of the source text.
- The service has no feature that makes your information visible to other people.
- We do not create or process pseudonymized information.
- The service is not intended for children under 14. If we learn that an account belongs to a child under 14, we delete its information.

## 2. Purposes and legal grounds

| Purpose | Information | Ground |
|---|---|---|
| Identify you, keep you signed in, delete your account | Account, automatically generated | Performance of our agreement with you (PIPA Art. 15(1)(4)) |
| Find the work you committed to, merge it with existing tasks, and apply changes to due dates and scope | Connections, source text, derived information, profile | Performance of our agreement. Sending to external AI also requires your in-app consent (section 4) For other people's information inside your sources, see "Other people's information inside your sources" below |
| Send review requests and due-date notifications | Device and notifications | Performance of our agreement |
| Measure whether the service works (share of tasks the AI got wrong, share of missed tasks, return visits) | Usage records | Our legitimate interest in improving the service (PIPA Art. 15(1)(6)). Not used to profile you for advertising |
| Fix errors and prevent abuse and security incidents | Automatically generated | Our legitimate interest; legal obligations |
| Answer support requests | Support | Your request |

We do not use information beyond these purposes. If a purpose changes, we will tell you in advance and ask for consent again where the law requires it.

### Other people's information inside your sources

The email, notes, and messages you connect contain names, email addresses, and statements of people other than you (email senders, meeting attendees, Slack conversation partners, transcript speakers). We use this information only to find the work you are responsible for and to show who a commitment was made with. We do not analyze these people separately or build profiles of them.

- **Legal ground:** our legitimate interest (Personal Information Protection Act, Art. 15(1)(6)). It is finding your own commitments in work sources that you chose to connect, and the processing is limited to that purpose.
- **Minimization:** source body text is deleted 90 days after it is stored. The people involved (names and email addresses), titles, and evidence quotes remain with your tasks until you delete your account (section 5; anything from Slack is deleted when you disconnect). Anything sent to external AI goes only to providers that keep no data (section 4).
- **Their rights:** a person whose information appears in your sources can ask privacy@taskforcelabs.dev where we got it, why we process it, and about their right to stop the processing (Art. 20 of the same Act), and can ask us to stop processing or delete it. We act on such requests without delay, and where the law allows us to refuse, we will say why.

## 3. What we do with each connected service

You connect each service yourself in the app's Connections screen and can disconnect at any time. We only **read** from connected services. We never send email or change events, documents, or messages.

When you disconnect (app → Connections → Disconnect), the service's access token is deleted immediately, we ask the service to revoke it, and we stop reading from it. For Notion and Google, **source text already imported, and tasks created from it, remain.** Slack is different: when you disconnect or remove the app in Slack, **we delete the text we got from Slack right away and keep only your tasks** (see Slack below). To delete everything, delete your account (section 5).

### Notion

- **What we read:** only the pages and databases you select on Notion's permission screen (including their child pages): page title, body text (text only; images are removed), meeting date, people properties (names and email addresses), last edited time, and who last edited it. For databases you confirm as task databases, we read only the title, assignee, due date, and status properties instead of the body.
- **What we don't read:** pages you did not select, recording transcript blocks, attachments.
- **What we store:** the body of imported pages (up to 200,000 characters each), title, people involved, original link, last edited time. Your Notion workspace name and identifier.
- **Access:** we request read-content access only. You can also remove Taskforce in Notion under Settings → Connections.

### Google (Calendar and Meet transcripts)

- **What we read from Calendar:** event titles, start and end times, organizer and attendees (names and email addresses), and the Google Meet conference identifier on your calendars. We do not read event descriptions or attachments.
- **How Calendar is used:** events are not used as sources of tasks. We use them to attach attendees to the meeting notes (Notion) and Meet transcripts from the same time, which helps decide whose task something is. The attached event title, time, and attendees are stored as the people involved in that meeting source.
- **What we read from Meet:** your Google Meet conference records and transcripts (speaker name, what was said, time). Google provides transcript entries through its API for only 30 days after a meeting ends, so we import them within that window.
- **What we store:** the transcript text with speaker names, the meeting title and time, attendees.
- **Access:** `calendar.events.owned.readonly` (read events on calendars you own) and `meetings.space.readonly` (read Meet conference information and transcripts). We never create or change events or meetings.

### Gmail

- During the beta, Gmail is **connected separately** from Google Calendar and Meet. While Google reviews it, Gmail runs in Google's Testing mode: only users registered as test users can connect it, and **you need to reconnect every 7 days.** We tell you in the app and by notification when the connection expires.
- **What we read:** email threads you sent or received: subject; sender, recipients, and CC (names and email addresses); date; and body. We filter out newsletters, promotions, and automated notifications (messages with an unsubscribe header or in the Promotions category) and do not store them. We do not read spam, trash, or attachments.
- **What we store:** the body, subject, people involved, date, and original link of the remaining threads.
- **Access:** `gmail.readonly` (read email). We never send, delete, or relabel email.

### Slack

- **How we receive messages:** through the Slack Events API, Slack sends our server messages posted in conversations you belong to. We never bulk-download conversation history.
- **What we keep:** direct messages with you, group DMs you are in, and channel messages that mention you or that you wrote, plus messages in threads you wrote in or were mentioned in. **Channel messages that match none of these are discarded on arrival and never stored.** We do not fetch messages posted before you connected.
- **What we store:** kept messages wait in a queue; once a conversation has been quiet for 30 minutes we group them by conversation or thread and store them as source text, and once processing finishes we clear the text in the queue. Source text includes the grouped messages, sender names, times, and original links. When a task is created, the message line it came from (the evidence quote). Your Slack workspace name, address, and identifier; the Slack user identifiers and names of you and the people you talk with; and conversation names (channel names and who a DM is with). Source body text is deleted 90 days after it is stored (section 5).
- **Access:** user-token conversation read scopes (`im:history`, `mpim:history`, `channels:history`, `groups:history`), conversation info (`im:read`, `mpim:read`, `channels:read`, `groups:read`, to know channel names and who a DM is with), and user names (`users:read`). We install no bot, and we never send or edit messages.
- **When you disconnect or remove the app:** when you disconnect in the app, we ask Slack to revoke the token; when you remove the Taskforce app or revoke its access in Slack, we delete the stored token. In both cases we immediately delete the body text, title, and people involved of the Slack source text, the quote text of claims, Jev judgment records, queued messages, tracked threads, and name information, and each evidence quote is replaced by a removal note. If Slack fails to tell us the app was removed, a daily token check deletes the same data within a day. What remains: tasks (title, due date, status, counterpart), change history, the embedding used to find similar tasks (a numeric vector), and original links. If you removed the app in Slack, the connection record (workspace name, address and identifiers, and your Slack user ID) remains in a "revoked" state until you disconnect it in the app.
- **Commitments:** we do not use data received from Slack to train any AI model, including large language models (LLMs); we do not use one workspace's data for another workspace or a third party; and we do not bulk-export it.

## 4. What we send to external AI

Taskforce uses external AI models to find tasks in source text, decide whether a new task is the same as an existing one, and find similar tasks.

### What we send

- Source text from connected services (body, title, date) and the names and email addresses of the people involved
- Your display name, aliases, and email addresses, so the model can recognize you in the text
- Titles and evidence quotes of existing tasks, to compare with newly found candidates
- (When you use Ask) your question and the related tasks and evidence quotes

### Who receives it, and under what conditions

- Every AI request goes through **OpenRouter, Inc.** (USA) to a model provider. Recipients and countries are listed in the table in section 7.
- Every request requires "route only to providers with Zero Data Retention" and "do not use providers that collect or train on data". If no provider meets these conditions, the request fails; we never retry with weaker conditions.
- OpenRouter prompt logging is turned off.
- Nothing we send is used to train any AI model, ours or anyone else's.

### Consent and withdrawal

- Before you connect your first service, the app shows you this information and asks for your consent. **If you do not agree, the server does not send or process source text from connected services.**
- You can withdraw consent at any time in app → Account → AI data. After you withdraw, new source text is not sent to AI, so no new tasks are created. Existing tasks remain; to delete them, delete your account.
- "Hand off to AI" packages a task's context as text and shows it in the app. If you paste that text into another AI tool, you are doing so yourself; we do not send it.

## 5. Retention and deletion

### Retention

| Information | Retention |
|---|---|
| Account, profile, sign-in sessions | Until you delete your account |
| Connections and access tokens | Until you disconnect or delete your account |
| Source text from connected services (body text) | **90 days after it is stored.** After 90 days we delete only the body text; the row, title, original link, people involved, and processing result remain until you delete your account (they remain after you disconnect). **For Slack, when you disconnect or remove the app,** we delete the body text, title, and people involved right away |
| Jev judgment records (including candidate quotes) | 90 days after they are stored. For Slack source text, right away when you disconnect or remove the app |
| Tasks, evidence quotes, change history, embeddings | Until you delete your account. Evidence quotes remain even after the source body text is deleted, except that evidence quotes from Slack are deleted when you disconnect or remove the app (the tasks and embeddings remain). A task you delete in the app disappears from your list but is kept in a "deleted" state so we can calculate the error rate |
| Queued Slack messages (before grouping into source text) | 3 days after they arrive. Once grouped into source text and processed, the text is cleared, and only a marker (conversation, message, and sender identifiers) is kept until 3 days after arrival so the same message is not received twice. Right away when you disconnect or remove the app |
| Tracked Slack threads (identifiers of threads you wrote in or were mentioned in) | 14 days after the last activity. Right away when you disconnect or remove the app |
| Slack name information (user and conversation names) | Until you disconnect or remove the app (a name older than 7 days is re-read when it is needed again) |
| Usage records | Until you delete your account |
| Push device tokens | Until you sign out, Apple reports the token invalid, or you delete your account |
| Server request records (Vercel) | 1 day |
| Database and authentication request records (Supabase) | 1 day |
| AI requests (OpenRouter and model providers) | Not stored; only while the request is processed |
| Support email | Identifiable content deleted within 90 days after the request is closed |

No law currently requires us to keep any of this information longer. If one does, we will list the legal basis and items here and store them separately.

### How we delete

- **Account deletion:** app → Account → Delete account. When the server deletes your authentication account, rows in every table linked to it (profile, connections and tokens, source text, tasks, evidence, history, judgment records, usage records, device tokens) are deleted in the same request.
  When you delete your account, we also ask Apple to revoke your Sign in with Apple tokens and ask each connected service to revoke its tokens.
- **Automatic deletion of source text:** a job runs daily and deletes the body text of source text stored 90 days ago, and deletes Jev judgment records stored 90 days ago. The same job deletes queued Slack messages that arrived 3 days ago and Slack threads with no activity for 14 days.
- **Disconnecting or removing Slack:** when you disconnect Slack in the app or remove the app (or revoke its access) in Slack, we delete that connection's Slack source body text, titles, and people involved, evidence quotes, claim quote text, Jev judgment records, queued messages, tracked threads, and name information at once (Slack in section 3). A daily check of Slack tokens runs the same deletion within a day even if we were not told the app was removed.
- **No backups:** we keep no database backups, so deleted data cannot be recovered and does not linger in a backup. If we start keeping backups, we will add their retention period to this policy first.
- **Logs:** server and database request records are deleted automatically by each provider after the periods above. These records do not contain source text.
- Electronic files are deleted so they cannot be recovered. We do not create paper records.

## 6. Disclosure to third parties

We do not provide or sell your personal information to third parties or use it for advertising. The only exception is a lawful request by an authority under applicable law.

## 7. Processors and international transfers

### Processors

| Processor | Service |
|---|---|
| Vercel Inc. | Server operation (API, scheduled sync), website hosting |
| Supabase Pte. Ltd. (storage infrastructure: Amazon Web Services) | Database, sign-in and authentication, authentication email |
| OpenRouter, Inc. | Routing AI requests |
| Model providers (through OpenRouter; see table below) | Running AI models |
| Apple Inc. | Delivering push notifications (APNs) |
| Google LLC (Google Workspace) | Receiving and storing support email |

We rely on each processor's data processing agreement and confirm that each processor protects personal information at least as well as this policy describes. If a processor changes, we update this policy first.

### International transfers (PIPA Art. 28-8)

Our server and database are outside Korea. All transfers happen over the network (TLS-encrypted) at the time you use the service.

| Recipient (contact) | Country | Items | Purpose | Retention |
|---|---|---|---|---|
| Vercel Inc. (privacy@vercel.com, 440 N Barranca Ave #4133, Covina, CA 91723, USA) | Australia (Sydney, server execution), USA (request records and management systems) | Everything that passes through the server (section 1), server request records | Server operation, website hosting | While the request is processed; request records 1 day |
| Supabase Pte. Ltd. (privacy@supabase.com) | Australia (Sydney, AWS ap-southeast-2) | All items in section 1 except support email | Data storage, sign-in and authentication | Until account deletion; request records 1 day |
| OpenRouter, Inc. (privacy@openrouter.ai) | USA | What we send (section 4) | Routing AI requests | Not stored (only while the request is processed) |
| Together AI, Inc. (privacy@together.ai) · Fireworks AI, Inc. (privacy@fireworks.ai) · Deep Infra Inc. (policy@deepinfra.com, 2625 Middlefield Road #460, Palo Alto, CA 94306, USA) · Baseten Labs, Inc. (privacy@baseten.co, 560 Davis St., Suite 250, San Francisco, CA 94111, USA) (through OpenRouter, finding tasks in source text) | USA (based on headquarters; the providers do not publish where the request is actually processed) | What we send (section 4) | Running AI models (source analysis) | Not stored (Zero Data Retention) |
| Microsoft Corporation (Azure, through OpenRouter, embeddings; privacy contact: go.microsoft.com/fwlink/?linkid=2126612, One Microsoft Way, Redmond, WA 98052, USA) | USA (based on headquarters) | The part of what we send (section 4) used to find similar tasks (titles and evidence quotes of new candidates and existing tasks) | Running AI models (embeddings) | Not stored (Zero Data Retention) |
| TypeSafe AI, Inc. (through OpenRouter, judgment; privacy@typesafe.ai, 255 California St, Suite 1300, San Francisco, CA, USA) | USA (address in TypeSafe's terms of use) | What we send (section 4) | Running AI models (judgment) | Not stored (Zero Data Retention) |
| Apple Inc. (One Apple Park Way, Cupertino, CA 95014, USA · apple.com/legal/privacy/contact) | USA | Push device token, notification content (task identifier and a generic phrase such as "Review needed"; task titles are never included) | Delivering push notifications | Under Apple's policy |
| Google LLC (1600 Amphitheatre Parkway, Mountain View, CA 94043, USA) | USA and other countries where Google has data centers | Email address and content of support email | Receiving and storing support email | 90 days after the request is closed |

- **Ground for transfer:** entrustment and storage needed to perform our agreement with you, with the items above disclosed in this policy (PIPA Art. 28-8(1)(3)). Sending to external AI (section 4) additionally requires your in-app consent.
- **How to refuse, and the effect:** because our server and database are outside Korea, we cannot provide the service if you refuse international transfer. To refuse, stop using the service and delete your account. To refuse only the transfer to external AI, do not give, or withdraw, AI data consent. In that case we do not process source text from your connected services, and no tasks are created automatically.

## 8. When we look at your source text

We (the operator) look at your source text and tasks only:

1. When you ask us for help with a specific source or task, and only within that request
2. When it is strictly necessary to respond to a security incident or outage
3. When required by law

If we want to look at a source to analyze why a task was wrong or missed, or to use it as evaluation data, **we first tell you which source and why, and ask for your consent.** Evaluation data is used only after information that identifies people is removed.
When we look at a source, we record the date, what we looked at, and why.

## 9. Security measures

- **Administrative:** only one person, the privacy officer, handles personal information. We follow the access rules in section 8 and record every access. Operator accounts (server, database, code repository, Apple, Google, Slack, Notion, OpenRouter) use two-factor authentication.
- **Technical:**
  - All traffic is encrypted with TLS.
  - The database runs on hosting that encrypts data at rest (AWS). Access tokens for connected services are encrypted again with a separate key (AES-256-GCM) that exists only in the server's environment variables.
  - Every table has row-level security (RLS), so you can read only your own data. The token table cannot be read by the app, only by the server. Only the server writes tasks, evidence, and history.
  - The server verifies the signature of your sign-in token on every request.
  - Server logs never contain source text, tokens, or authorization codes.
  - Lock-screen notifications never include task titles.
- **Physical:** the server and database run in our processors' data centers (Vercel, Supabase/AWS) under their physical security. We run no servers of our own.
- **Breach response:** if personal information is leaked, we notify you and the relevant authorities within 72 hours of learning of it and take steps to limit the harm.

## 10. Cookies and similar technologies

- The app does not use cookies. Your sign-in session is stored in the device Keychain.
- The website (www.taskforcelabs.dev) has no analytics, no advertising tools, and no cookies.
- Our internal admin screens use a cookie only for the operator's sign-in. Users do not use these screens.

## 11. Your rights and how to use them

You can ask to access, correct, delete, or stop the processing of your personal information, and you can withdraw consent, at any time.

| To do this | How |
|---|---|
| See your tasks and evidence | Directly in the app |
| Change your name, aliases, or email addresses | App → Account → Profile |
| Edit or delete a task | Directly in the app |
| Disconnect a service | App → Connections → Disconnect. You can also remove access in each service (Google: myaccount.google.com/connections; Notion: Settings → Connections; Slack: your workspace's app management). For Slack, disconnecting also deletes the text we got from Slack (your tasks remain) |
| Withdraw consent to AI transfer | App → Account → AI data |
| Delete all your data | App → Account → Delete account |
| Any other access, correction, deletion, or restriction request | Email privacy@taskforcelabs.dev |

- We answer email requests within 10 days. We may ask you to write from your account email so we can confirm it is you.
- A legal representative or someone you authorize can make a request; we will confirm the authorization.
- We may refuse a request where the law allows it, and we will tell you why.

## 12. Automated decisions

Taskforce uses AI to find tasks, due dates, and owners in your sources and builds your list from them. This helps you organize your own work; it is not a decision that significantly affects your rights or obligations.
We ask you to confirm owners and due dates we are unsure of, and every task the AI creates carries the quote it came from (except quotes deleted when Slack is disconnected, section 3). You can correct or delete any result at any time and ask us to explain how it was produced.

## 13. Privacy officer

| Item | Details |
|---|---|
| Privacy officer | Cheonghyeok Song (Representative) |
| Email | privacy@taskforcelabs.dev |
| Phone | We take requests by email (privacy@taskforcelabs.dev) |
| Operator | 태스크포스 (sole proprietorship, business registration number 687-30-01972) |
| Address | 262-20, Galma-dong, Seo-gu, Daejeon, Republic of Korea |

Please send questions, complaints, or requests for remedies about personal information to the contact above.

## 14. Remedies in Korea

For counseling or dispute resolution about privacy violations, you can contact:

- Personal Information Dispute Mediation Committee: +82-1833-6972, www.kopico.go.kr
- Personal Information Infringement Report Center (KISA): 118, privacy.kisa.or.kr
- Supreme Prosecutors' Office: 1301, www.spo.go.kr
- Korean National Police Agency: 182, ecrm.police.go.kr

## 15. Google user data

For information Taskforce receives through Google APIs (Calendar events, Meet transcripts, Gmail messages), we make these commitments:

> Taskforce's use of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.
>
> The use of information received from Google Workspace scopes will adhere to the [Google User Data Policy](https://developers.google.com/workspace/workspace-api-user-data-developer-policy), including the Limited Use requirements.

Specifically:

- We use Google data only for features visible in the app: finding and showing the work you committed to, and linking sources from the same meeting.
- We do not use Google data for advertising, credit assessment, or data sales, and we do not transfer it to third parties such as advertising platforms or data brokers.
- We do not use Google data to create, train, or improve generalized AI or machine learning models. We send it to external AI models only when needed to provide these features, only after you consent in the app, and only to providers that keep no data (section 4).
- No person reads Google data, except when you have explicitly agreed to let us view specific data, when necessary for security purposes (such as investigating abuse), when necessary to comply with applicable law, or when the data is aggregated so that no one can be identified and used for internal operations.
- We transfer Google data only to provide these features, for security, to comply with law, or as part of a merger or acquisition with your explicit prior consent.

## 16. Users in the EU and UK

The beta is not offered to people who live in the European Economic Area (EEA, including the European Union) or the United Kingdom (Terms of Use, section 4.3). We do not advertise there, and the app is not made available in those App Store regions. If the EU or UK General Data Protection Regulation (GDPR, UK GDPR) still applies to you:

- **Controller:** 태스크포스 (Republic of Korea), privacy@taskforcelabs.dev. We have not appointed a Data Protection Officer.
- **Legal bases:** providing the service: performance of a contract (Art. 6(1)(b)); sending to external AI: consent (Art. 6(1)(a)) and performance of a contract; service metrics, security, and processing other people's information in your sources: legitimate interests (Art. 6(1)(f)). Our legitimate interest is finding your own commitments in the work sources you connect, and we use the information for nothing else.
- **International transfers:** your information is transferred outside the EU and UK (to Korea, Australia, the USA, and others). Our processors' data processing agreements include the European Commission's Standard Contractual Clauses (SCCs) or equivalent safeguards. You can request a copy at the contact above.
- **Your rights:** access, rectification, erasure, restriction, portability, objection, and withdrawal of consent (without affecting the lawfulness of processing before withdrawal). You have the right to lodge a complaint with the supervisory authority in the EU member state or the UK where you live.
- **Whether you must provide data:** account information is needed to use the service. Connecting services and consenting to AI transfer are optional, but without them no tasks are created automatically.
- **Automated decisions:** we make no decisions with legal or similarly significant effects under Art. 22 (section 12).

## 17. Changes to this policy

- We announce changes in the app and on this page at least 7 days before they take effect. Changes that are less favorable to you, such as new items, purposes, or recipients, are announced 30 days in advance, and we ask for consent again where needed.
- Previous versions remain available on this page.

This policy takes effect on {{effective date}}.
