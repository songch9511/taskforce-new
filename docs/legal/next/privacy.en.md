# Privacy Policy

Taskforce (AI project manager) · Beta

- Effective date: {{effective-date-1.7}}
- Version: Beta 1.7
- 한국어: [개인정보 처리방침](privacy.ko.md) (the Korean version prevails if the two differ)

태스크포스 ("we", "us") operates the Taskforce app (iOS and macOS), its server, and the website (www.taskforcelabs.dev). We process your personal information under the Personal Information Protection Act of the Republic of Korea (PIPA) and other applicable laws.
This policy explains what we process, why, where, and for how long, and how you can stop or delete that processing.

## At a glance

- Taskforce reads meeting notes, messages, and email from the services **you connect** (Notion, Google, Slack) and finds the work you committed to. When you start a draft for that work (such as an email or document), it writes the draft and saves it in the app. We use your source text only for this. We do not send drafts to their recipients; you send them yourself.
- To find that work and write drafts, we send source text to external AI models. **We do not send anything until you agree in the app.** AI requests go only to providers that keep no data (Zero Data Retention), and nothing is used to train any AI model. With your own OpenRouter key (Lifetime), requests run through your OpenRouter account; we still require Zero Data Retention routing, and that account's own settings, such as logging, are yours.
- Your app data is stored on servers and a database in Sydney, Australia. Resend sends authentication emails from Tokyo and stores their content and delivery records in the United States (sections 5 and 7). We keep no database backups, so **completed account deletion removes your app data right away.** Limited billing retry records and the merchant's records are described in "Plans and payment data" below.
- We read your source text **only when you ask us to, or while responding to a security incident.** If we want to look at a source to analyze an extraction error, we ask for your consent first.
- Agents you connect yourself (such as Claude Code) run on your Mac under your own account. What an agent sends to a model provider is not sent by us, so the AI promises above do not apply to it. Our server stores the messages and replies you exchange with an agent and keeps them until you delete your account. A message you send from the Mac app to a session open in the Claude desktop app, and the reply that follows, are also stored on our server, and the app shows no notice that they are being saved. They stay until you delete them or delete your account; how to delete them is in the "Agents" section below.
- When you talk to Taskforce to ask about and organize your work, your messages, tasks, memories, and source excerpts are also sent to external AI under the same conditions (only after you agree, and only to providers that keep no data). There is no screen to delete conversations, so they stay until you delete your account, and when you "forget" a memory its text remains as history (see "Conversations with Taskforce, memory, and review").
- We do not sell your information or use it for advertising. The website has no analytics and no cookies.

## Plans and payment data

When you start a Pro or Lifetime checkout in the Mac app, we send Lemon Squeezy a random checkout reference, your selected plan and price variant, and whether a trial or first-month discount applies, so that the payment can be connected to your Taskforce account. We do not send your connected-source text, tasks, Google tokens, AI prompts, or OpenRouter key. You provide your email, billing details, and payment information directly on Lemon Squeezy's checkout; the payment method for a Pro trial is also collected by Lemon Squeezy. Taskforce does not receive or store full card numbers or security codes.

Lemon Squeezy acts as merchant of record and processes payment, fraud prevention, tax, receipts, refunds, and transaction retention under its [Privacy Policy](https://www.lemonsqueezy.com/privacy) and [Buyer Terms](https://www.lemonsqueezy.com/buyer-terms). Its policy identifies processing in the USA and countries where its providers operate. Payment is separate from source integrations and AI consent. Without paying, you can still view your saved tasks, results, and sources (free access for existing beta users is described in section 2A of the Terms of Use).

To provide your plan, prevent duplicate charges, make sure the trial, the first-month discount, and the in-app refund are each used only once per account, handle cancellations and refunds, and respond to billing issues, our server stores your account identifier, trial and subscription dates and the time of your first subscription, plan, customer/subscription/order/invoice identifiers, payment status and paid-through date, time of the last payment, Lifetime order status and payment time, the time you requested a refund and the time you used the in-app refund, checkout reference/URL/expiry and the trial and discount offered with it, accepted terms version and time, and a webhook digest and processing time to prevent duplicate processing. A retry inbox stores only the payment event type, provider object identifier, checkout reference, mode flag, and receipt/processing times for up to 7 days. We do not retain raw payment webhook bodies. These records are stored with our app database in Sydney. Account-linked billing records are deleted when account deletion completes. A pseudonymous checkout retry record, with its account link and checkout URL removed, is retained for late-payment cancellation and removed by the daily cleanup after its expiry plus 7 days. Lemon Squeezy's own transaction records follow its retention obligations and are not deleted by deleting Taskforce.

**Your OpenRouter key (Lifetime):** if you have Lifetime, the OpenRouter API key you add in the Mac app is encrypted on our server with a separate key (AES-256-GCM) and stored with its status (connected or revoked) and the times it was checked, last worked, was marked revoked, and last hit a payment error. Before saving it, we check once with OpenRouter that the key can be used. We use the key only for your own AI requests, never show it again to the app or to you, and never write it to server logs or error messages. We delete it when you remove it, when a Lifetime refund is confirmed, or when you delete your account.

## Agents (Claude Code and others)

When you send a message to an agent you connected yourself in the Mac app (today, Claude Code), Taskforce passes that message to the agent on your Mac, shows the agent's replies, questions, and file changes in the app, and lets you approve or stop them. The agent runs **only on your Mac**, not on our servers. During the beta, this works only on accounts we have enabled.

**The agent is yours.** The agent runs under your own login, the one you set up in Claude Code yourself. Taskforce does not read, store, or send the agent's login information or tokens to our server. What the agent sends to a model provider (for example, Anthropic) is not sent by us. So the promise in section 4 that requests go "only to providers with Zero Data Retention" does not apply to it, and the terms and policy between you and that service govern it. It is a service you use directly, so we have not listed it in the processor table in section 7. Usage fees for the agent are between you and that service (Terms of Use, section 2A paragraph 5 and section 6A).

**Registering this Mac.** While you are signed in, a Mac app with the agent feature turned on registers this Mac as a device and sends a status signal to our server every 30 seconds. The server stores a device identifier (a hash computed from a random value the app created), the Mac's name (the computer name set on the system, up to 64 characters), the app version, whether the agent is installed, its version, whether it is signed in (yes, no, or unknown), whether managed settings are present, and the time of the last signal. The status signal also carries the identifiers and states of tasks in progress. The device secret stays in this Mac's Keychain; the server stores only its hash. Claude Code is used only after you connect it yourself in Settings → Connections → Your agents (Connect), and you can disconnect at any time with Disconnect this Mac in the same place. Disconnecting deletes this Mac's name and the "other Claude Code sessions" list below from our server, but conversations already stored remain.

**What our server stores.** The messages you send to an agent, the agent's text replies and questions (cut short if long), approval requests, and your answers are stored as an agent conversation so you can see them on your other devices too. An approval request contains either the path, relative to the working folder, of a file the agent wants to change, or the command it wants to run (up to 300 characters). Secret input such as a password is not sent to our server; it is entered into the agent on this Mac. A session stores a display name (up to 80 characters of the first line of the first message, or the name you set), a session identifier chosen by the agent, a random identifier that points to the working folder, and its progress and times. For a file the agent created or changed, we record only its path relative to the working folder, a hash of its contents, and a one-line summary ("Edited path"), and we also record the relative path of the file being changed so that two jobs do not edit the same file at once. If a message creates a new task, the message text is also stored as that task's evidence quote and as a "Taskforce conversation" source. The source text is deleted after 90 days, and the evidence quote stays with the task until you delete your account (section 5).

**What we do not send to our server.** The contents of files the agent reads or writes and what changed in them, tool results, your Claude Code settings and login information, and the name and real path of the working folder (the Mac replaces it with a random identifier before sending). However, the command the agent wants to run is sent to our server as written so that the server can decide whether to allow it (used only for that decision and not stored), and when approval is requested, the command is stored up to 300 characters as described above. If a command contains a path or folder name from your Mac, it is included as written. Our server does not send the messages and replies you exchange with an agent to external AI. If a message creates a new task, however, that task may be used as described in section 4.

**Other Claude Code sessions on this Mac.** The Mac app reads, only on this Mac, the file names, modification times, working folders, and session titles of the Claude Code session records stored on this Mac (those started in a terminal or in the Claude desktop app) and shows them under "On this Mac" on the Sessions screen. It reads only parts of the head and tail of each record file, does not read the conversation text, and does not send working folder names or paths or conversation content to our server. When you open a Claude desktop app session in Taskforce, its conversation is likewise only read on this Mac and shown on screen (it is stored only when you send a message, as described under "Talking to a Claude desktop app session" below). However, so that this list can also be shown on your other devices, we upload to our server, for up to 50 sessions used in the last 7 days or open now, the **title** (up to 200 characters; it is the session name Claude Code chose and may be a summary of your first question), the state (for example, open in the desktop app, open in a terminal, or not open), the time of last activity, and an identifier made only on this Mac (the session number converted with a secret key that exists only on this Mac, so we cannot tell which session it is). Each time this Mac uploads a new list, the list on the server is replaced and the titles of sessions that disappeared are deleted; if uploading stops, the list is deleted after 14 days. When you sign out, the app clears this Mac's list from our server and stops uploading.

**Resuming a session.** When you resume in Taskforce a Claude Code session that you started outside Taskforce (in a terminal or in the Claude desktop app), we store the identifier of the resumed session. The server receives from that session only the Claude session identifier (a random string) and a random identifier that points to the working folder; we do not upload the conversation from before you resumed. Messages you send after resuming and the agent's replies are handled like the agent conversation above.

**Talking to a Claude desktop app session (Mac).** When you send a message from the Mac app to a session open in the Claude desktop app, we store on our servers the message (once the session is confirmed to have received it), the session's text replies that follow it, and the names of the tools used while replying (for example, Edit or Bash), so you can see them on your other devices. If you sent the message while the session was already working, replies to that work may be stored with it. We do not store what was passed to a tool or its results, file paths or commands, conversation you type directly in the desktop app, or working folder names and paths. Sessions are told apart by an identifier made only on your Mac and the session title, and delivery to the session happens only on your Mac. We keep stored conversations **until you delete them or delete your account.** You can delete one conversation by opening it in the Mac app under Sessions → Saved chats, or delete all of them at once with Delete all saved chats under Settings → Account. The app shows no notice that this is being saved, so please understand that messages sent with this feature and their replies are stored.

**Consent and deletion.** If you have not given, or have withdrawn, AI data consent (section 4), you cannot send or resend messages in an agent conversation that goes through our server. There is not yet a screen to delete an agent conversation one by one, so it stays until you delete your account. To delete one, email privacy@taskforcelabs.dev (section 11). Stored Claude desktop conversations can be deleted directly in the app as described above.

## Conversations with Taskforce, memory, and review

This covers talking to Taskforce (the AI) in the Mac app to ask about and organize your work, the memories and projects that come out of it, and the review list and return summary our server computes for you. Each feature is turned on by a server switch (off by default), and during the beta we turn them on in stages. Conversations with Taskforce work only on accounts we have enabled.

**Talking to Taskforce.** When you send a message, Taskforce looks at your tasks, memories, and source excerpts, answers, and helps you organize your work.
- What our server stores: the conversation title (up to 200 characters), the messages you send (up to 4,000 characters), Taskforce's replies (each part is marked as a confirmed record, something you said, or a suggestion), the evidence quotes, source titles, and links attached to a reply, suggestions and confirmation cards, the targets you attach (identifiers of tasks and projects), and the result of judging your intent (type and confidence).
- What we send to external AI is listed in section 4, "When you talk to Taskforce". We do this only after you give the in-app AI data consent, and we check the consent again right before every call. Without consent, we do not even store the message.
- What it can write besides a reply: saving a memory (only when there is a quote taken word for word from what you said and confidence is high), adding a new task (only when you adopt what Taskforce suggested with "yes" or a button), and organizing (moving a task to another project happens right away when confidence is high; deleting and merging happen only after you confirm on a card. A deleted task remains in a "deleted" state, section 5).
- We do not delete conversation text automatically, and there is not yet a screen to delete a conversation, so it stays until you delete your account. The evidence quotes and source titles in a reply are replaced with a placeholder or blanked when you disconnect Slack or the source row is deleted; the 90-day retention cleanup leaves the quotes in place. The reply text itself can contain words from the source (including Slack).
- We do not write message text to server logs.

**Memory.** From what you say in a conversation, we save things worth keeping (preferences, conditions, facts) as "memories". A memory has a sentence (up to 1,000 characters), a type, a subject, and a value, its source (the conversation message and the quote taken from your text), its scope (everything, a project, a task, and so on), and the time you said it. Today only things you say in a conversation and text you rewrite yourself become memories; we do not create memories automatically from the text of connected services. In the Mac app's Settings (Remembered) you can confirm, edit, move the scope of, or forget a memory. A forgotten memory and the older text before an edit disappear from the screen and from replies but stay on our server as history, and are deleted when you delete your account. When you connect a service, we also save one line with that account's identifier (for Slack, team:user; for Google, the account identifier and, if the display name looks like an email address, that address) as an "address that identifies you" so we can recognize you in source text; we delete it when you disconnect.

**Projects.** We store the name and icon of projects that group your tasks, and which project each task belongs to. The project name is sent to AI when a reply is produced in a conversation. A project you archive is only hidden, not deleted.

**Source chunks and search.** After we process source text from your connected Notion or Google (including Gmail), we split it into chunks of 1,000 to 2,000 characters (up to 200 chunks per source), send them to the embedding provider (sections 4 and 7) to produce numeric vectors, and store the chunk text and vectors on our server. We do not make chunks from Slack source text or pasted text. In a conversation that has a project, we find chunks similar to your question and use them as material for the reply. We do not make chunks without consent. When the source text is deleted after 90 days, its chunks are deleted too; if you disconnect Google or Notion, the chunks remain, as the source text does. Chunks of a source whose access we have lost are only left out of search.

**Event records.** Our server queues "events" in an event inbox when source processing finishes, when a conversation message arrives, when you confirm, delete, edit, or complete a task, when you approve an execution, when a project's memories or membership change, and when a due date comes within 24 hours. An event holds only a type, identifiers, and times, with no text. Except for due-date events, events are queued even when the server switch is off; when it is on, due-date events are queued too and code works out which tasks are affected and records only the kind of result. It does not call an AI model. We do not delete event records automatically; they stay until you delete your account.

**Review and return summary.** Review is a list our server orders, most urgent first, of what needs your decision now (tasks to confirm, execution steps waiting for approval, and, for agents, questions, approval requests, results ready, and file path conflicts), sent as identifiers, types, and times; the app reads the text itself with your permissions. The server stores the state of suggestions (a due date is near, an execution failed, review again after a source was edited), which is open, snoozed, dismissed, expired, or accepted, and its times. The return summary collects what changed since you last looked: when you ask, the server reads the current titles of your tasks and puts them in the response, and stores where you have read up to (read marks and the baseline time of the first display). Neither feature uses an AI model or sends a push notification or email. The stored state is not deleted automatically and stays until you delete your account.

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
| Account | Sign in with Apple: your Apple user identifier and email address (if you choose "Hide My Email", the relay address Apple creates). Sign in with Google: your Google account identifier, email address, name, profile photo URL, and, for Google Workspace accounts, your organization's domain (the values Google provides at sign-in; we do not store Google's tokens on our servers). Email sign-in: your email address and sign-in verification code. We do not receive your name from Apple. When you sign in with Apple on a Mac, Apple returns the sign-in result to the app through Taskforce's server, which does not store or log it. If you add another sign-in method to your account, we also receive that method's items above | When you sign in |
| Authentication email | Recipient email address, subject, body containing a verification code, sending time and delivery outcome | Generated by Supabase and sent through Resend when you request sign-in or other account verification |
| Profile | Display name, aliases, additional email addresses | You enter them, or ask us to (name and aliases in the app) |
| Connections | The connected service, workspace or account identifier and name (for Google, the account's email address), connection settings (names and identifiers of databases to include or skip; for Google, the permission scopes you granted and, for Gmail, counts of emails by reason), sync status (where the last import reached; for Gmail, the identifier and received time of recently imported or filtered emails), access tokens (stored encrypted) | When you connect a service in the app |
| Source text from connected services | Meeting notes, documents, task database entries, calendar events, meeting transcripts, emails, and Slack messages, with their titles, times, original links, and the people involved (names and email addresses of senders, recipients, attendees, and speakers). See section 3 for each service | Through the connected service's API |
| Pasted source text | Text you paste into the Mac launcher (such as meeting notes or messages) and its title (the first line) | You enter it in the app |
| Information derived from source text | Task title, scope, due date, owner, counterpart name, evidence quotes, a record of who said what and when, change history, AI judgment records (candidates and probabilities), numeric vectors used to find similar tasks (embeddings) | When the server processes a source |
| Drafts | What you asked for on a task; the title and body of the draft the AI wrote; and, while writing it, the instructions the AI set, suggested recipients (names and email addresses from the material), and questions it asks you back | When you start a draft in the app, and when the server writes it |
| Run records | Status, outcome type, and times of each draft run and its steps; the model and prompt version used; error type; a record of status changes (no text); and the draft record attached to the task (the evidence line "초안 저장: [draft title]" ("Draft saved") and an in-app link to the draft) | When the server writes a draft |
| AI usage and credits | For each AI request, OpenRouter's request identifier, the model, token counts, and cost (no text); credits we grant you and the records of reserving, using, and releasing them (credit amounts, rate, confirmed cost). Plan and payment records and your OpenRouter key are described in "Plans and payment data" above | When the server writes a draft, and when we grant credits |
| Agent connection (Mac) | A hash identifying this Mac (computed from a random value the app created), the Mac's name (computer name, up to 64 characters), app version, whether the agent is installed, its version, whether it is signed in (yes, no, or unknown), whether managed settings are present, connection status, time of the last status signal, and a hash of the device secret (the secret itself exists only in this Mac's Keychain) | When the Mac app registers this Mac and sends status signals |
| Agent conversation | Messages you send to an agent and the context chips you attach (identifiers of tasks, projects, and similar), the agent's text replies, questions, and status lines, approval requests (for a file change, the path relative to the working folder; for running a command, up to 300 characters of the command) and your answers, and delivery status. Secret input is not sent to our server | When you send from the app, and when the agent replies |
| Agent session and file records | The session's display name, the session identifier chosen by the agent (for a resumed session, that session's identifier), a random identifier that points to the working folder (not the folder name or path), progress and times, for each file the agent created or changed its path relative to the working folder, a hash of its contents, and a one-line summary, and a record of file paths (relative to the working folder) kept so that two jobs do not edit the same file at once. No file contents | While the agent works |
| Other Claude Code sessions list | For each other Claude Code session on this Mac: a title (up to 200 characters), a state, the time of last activity, and an identifier made only on this Mac. No working folder names, paths, or conversation text | The Mac app reads parts of the head and tail of this Mac's session record files and uploads these items |
| Stored Claude desktop conversations | A message you sent from the Mac app to a session open in the Claude desktop app (once the session is confirmed to have received it), the session's text replies that follow it, the names of tools used while replying (names only), the session title (up to 200 characters), an identifier made only on this Mac that tells sessions apart and this Mac's device identifier, and the times the text was written. No input passed to tools, results, file paths, commands, conversation typed directly in the desktop app, or working folder names or paths | When you send a message from the Mac app to a session open in the Claude desktop app |
| Conversations with Taskforce | Conversation title, your messages, Taskforce's replies (with part markers), evidence quotes, source titles, and links attached to replies, suggestions and confirmation cards, the targets you attach (identifiers of tasks and projects), and the result of judging your intent (type and confidence) | When you send from the app, and when the server produces a reply |
| Memory and "address that identifies you" | A memory's sentence, type, subject, value, scope, source (the conversation message identifier and the quote from your text), the time you said it, and its edit history; when you connect a service, that account's identifier (for Slack, team:user; for Google, the account identifier and, if the display name looks like an email address, that address) | When you speak in a conversation or edit in Settings (Remembered), and when you connect a service |
| Projects | Project name and icon, which project each task belongs to, and whether it is archived | When you create a project or move a task |
| Source chunks | Chunks of your connected Notion or Google source text (1,000 to 2,000 characters) and their numeric vectors (embeddings) | After the server processes source text |
| Event records, review suggestions, return summary state | An event's type, identifiers, time, and the kind of result (no text); a suggestion's type, the identifier of the task it concerns, its state and times; the return summary's read marks and baseline time | When the server queues an event, and when you use review or the return summary |
| Usage records | App opens; starting, completing, editing, deleting, or confirming a task; use of "Hand off to AI"; weekly question answers; times you reported a missing task; requests for services we do not support yet; records of completing a connection, of a connection expiring so that you need to reconnect, of sending a reconnect notice, and of closing a source as failed (service name and time only); agent usage records (sending a message, stopping, answering a question, renaming a session, resuming a session; the result of opening a Claude desktop session and of sending a message to it, and of deleting stored conversations; the result code and duration of each tool-use decision; and a count range for each day the other-sessions list was shown. These contain no text, titles, paths, or commands, only the type, a code, and the time) | When you use the app, or when the server syncs your connections, processes a source, or handles an agent |
| Device and notifications | Push notification device token (APNs), platform (iOS or macOS), app version, last seen time | After the app receives notification permission |
| Task list stored on your device | The last task list, so the app can show it until a fresh list arrives (for example, while you are offline) (task title, due date, and status only; no source text or evidence), kept separately for each account | When the app receives your tasks from the server (stored only on your device) |
| Agent information stored only on this Mac | The agent work record (the processing record of delivery requests from the server, agent reply text and events not yet uploaded to the server, and the full text of replies that were cut short when uploaded), a list of working folders (pairs of the real path and the random identifier used on the server), per-session state (the agent session identifier and working folder), this Mac's device secret (Keychain), and the secret key used to build the session list | When you use the agent feature (stored only on your Mac) |
| Automatically generated | IP address and device information (User-Agent) of your sign-in session; server request records (path, time, status code, short error message) | Generated while you use the service |
| Support | Your email address and message | When you email us |

- We do not ask for national identification numbers or sensitive information. If your connected notes, messages, or email contain such information, we do not separate it out; it is processed the same way as the rest of the source text.
- The service has no feature that makes your information visible to other people.
- We do not create or process pseudonymized information.
- The service is not intended for children under 14. If we learn that an account belongs to a child under 14, we delete its information.

## 2. Purposes and legal grounds

| Purpose | Information | Ground |
|---|---|---|
| Identify you, send sign-in verification email, keep you signed in, delete your account | Account, authentication email, automatically generated | Performance of our agreement with you (PIPA Art. 15(1)(4)) |
| Find the work you committed to, merge it with existing tasks, and apply changes to due dates and scope | Connections, source text, derived information, profile | Performance of our agreement. Sending to external AI also requires your in-app consent (section 4). For other people's information inside your sources, see "Other people's information inside your sources" below |
| Write a draft you start for a task (such as an email, document, or list of questions) and save it in the app (during the beta, only on accounts we enable) | Derived information (tasks and evidence quotes), excerpts of source text with their titles, dates, and people involved, your name, drafts, run records | Performance of our agreement (your request). Sending to external AI also requires your in-app consent (section 4) |
| Count the credits a draft uses, check AI costs, and apply the Pro fair-use limit | AI usage and credits | Counting credits and applying the fair-use limit: performance of our agreement; checking AI costs: our legitimate interest (PIPA Art. 15(1)(6)). Execution credits are separate from plan payments |
| Provide your plan, confirm payments, handle cancellations and refunds, answer billing questions | Plan and payment records ("Plans and payment data" above) | Performance of our agreement |
| Send Lifetime AI requests through your OpenRouter account | OpenRouter key | Performance of our agreement (your request) |
| Pass your messages to an agent and show its replies, questions, and approval requests; register this Mac and check connection status; coordinate so two jobs do not edit the same file at once and decide whether to allow a tool use (during the beta, only on accounts we have enabled) | Agent connection, conversation, session, and file records | Performance of our agreement (your request). For agent conversations that go through our server we also ask for your in-app consent first (section 4) |
| Let you see on your other devices: the other Claude Code sessions list, and conversations with Claude desktop app sessions | Other Claude Code sessions list, stored Claude desktop conversations | Performance of our agreement (your request) |
| Answer you in conversations with Taskforce and help organize your work, save memories, and find related material in source chunks (during the beta, only on accounts we have enabled) | Conversations with Taskforce, memory, projects, source chunks | Performance of our agreement (your request). For the parts sent to external AI we also ask for your in-app consent (section 4) |
| Queue events and work out affected tasks; compute the review list and return summary | Event records, review suggestions, return summary state | Performance of our agreement |
| Send review requests, due-date notifications, and connection-expiry (reconnect) notices | Device and notifications | Performance of our agreement |
| Show your last task list until a fresh list arrives (while you are offline or the list cannot be refreshed) | Task list stored on your device (on your device only) | Performance of our agreement |
| Measure whether the service works (share of tasks the AI got wrong, share of missed tasks, return visits, delivery results of agent messages and the time tool-use decisions take) | Usage records | Our legitimate interest in improving the service (PIPA Art. 15(1)(6)). Not used to profile you for advertising |
| Fix errors and prevent abuse and security incidents | Automatically generated | Our legitimate interest; legal obligations |
| Answer support requests | Support | Your request |

We do not use information beyond these purposes. If a purpose changes, we will tell you in advance and ask for consent again where the law requires it.

### Other people's information inside your sources

The email, notes, and messages you connect contain names, email addresses, and statements of people other than you (email senders, meeting attendees, Slack conversation partners, transcript speakers). We use this information only to find the work you are responsible for, to show who a commitment was made with, and to write the drafts you start for that work. We do not analyze these people separately or build profiles of them.

- **Legal ground:** our legitimate interest (Personal Information Protection Act, Art. 15(1)(6)). It is finding your own commitments in work sources that you chose to connect and, when you ask, writing a draft for that work, and the processing is limited to that purpose.
- **Minimization:** source body text, draft body text, what you asked for, and the draft instructions, suggested recipients, and questions are deleted 90 days after they are stored (if the draft run is still in progress at that point, what you asked for and the instructions, suggested recipients, and questions are deleted as soon as it ends). The people involved (names and email addresses), titles, evidence quotes, and draft titles remain with your tasks until you delete your account (section 5; anything from Slack is deleted when you disconnect). Anything sent to external AI goes only to providers that keep no data (section 4).
- **Their rights:** a person whose information appears in your sources can ask privacy@taskforcelabs.dev where we got it, why we process it, and about their right to stop the processing (Art. 20 of the same Act), and can ask us to stop processing or delete it. We act on such requests without delay, and where the law allows us to refuse, we will say why.

## 3. What we do with each connected service

You connect each service yourself in the app's Connections screen and can disconnect at any time. We only **read** from connected services. We never send email or change events, documents, or messages.

When you disconnect (app → Settings → Connections → Disconnect), the service's access token is deleted immediately, we ask the service to revoke it, and we stop reading from it. For Notion and Google (including Gmail), **source text already imported, and tasks created from it, remain.** Slack is different: when you disconnect or remove the app in Slack, **we delete the text we got from Slack right away and keep only your tasks** (see Slack below). To delete everything, delete your account (section 5).

### Notion

- **What we read:** only the pages and databases you select on Notion's permission screen (including their child pages): page title, body text (text only; images are removed), meeting date, people properties (names and email addresses), last edited time, and who last edited it. For databases you confirm as task databases, we read only the title, assignee, due date, and status properties instead of the body.
- **What we don't read:** pages you did not select, recording transcript blocks, attachments.
- **What we store:** the body of imported pages (up to 200,000 characters each), title, people involved, original link, last edited time. Your Notion workspace name and identifier.
- **Access:** we request read-content access only. You can also remove Taskforce in Notion under Settings → Connections.
- **When the connection expires or ends:** we show it on the app's Connections screen. If Notion rejects the refresh of the stored access token so that you need to reconnect (this can also happen after you remove Taskforce's access in Notion), we also notify you once. The notification contains only the service name (for example "Notion"), never source text or task titles.

### Google (Calendar and Meet transcripts)

- **What we read from Calendar:** event titles, start and end times, organizer and attendees (names and email addresses), and the Google Meet conference identifier on your calendars. We do not read event descriptions or attachments.
- **How Calendar is used:** events are not used as sources of tasks. We use them to attach attendees to the meeting notes (Notion) and Meet transcripts from the same time, which helps decide whose task something is; the attendees are also part of the material for drafts you start. The attached event title, time, and attendees are stored as the people involved in that meeting source.
- **What we read from Meet:** your Google Meet conference records and transcripts (speaker name, what was said, time). Google provides transcript entries through its API for only 30 days after a meeting ends, so we import them within that window.
- **What we store:** the transcript text with speaker names, the meeting title and time, attendees.
- **Access:** `calendar.events.owned.readonly` (read events on calendars you own) and `meetings.space.readonly` (read Meet conference information and transcripts). We never create or change events or meetings.

### Gmail

- During the beta, Gmail is **connected separately** from Google Calendar and Meet. Gmail is available through the OAuth app in Production, so users do not need to be registered as test users. Google has not yet verified the gmail.readonly scope. Until it is verified, Google displays an unverified-app warning during authorization and limits the OAuth app to 100 users over its lifetime. Newly issued Production refresh tokens are not subject to Testing mode's seven-day expiration. Existing connections may still need to be reconnected, and access may stop working if Google authorization is revoked or expires. We notify you in the app and by notification when a connection expires.
- **What we read:** the subject; sender, recipients, and CC (names and email addresses); date; and body of emails you sent or received. We do not read attachments (we only recognize them in order to skip them, and we do not store their names or types). Other headers that arrive with the body (such as BCC on email you sent; other than format headers used to decode the body) are not used or stored. When you first connect, we import the last 14 days of email (the same applies if you disconnect and connect again, or connect a different account). If the connection expired and you reconnect the same account, we resume from the last time we imported, or from 30 days ago if that gap is longer.
- **What we filter out:** we filter out newsletters, promotions, and automated notifications by the rules below and do not store them. Email that matches none of these rules is imported.
  - Mail in the Promotions or Social category, and spam, trash, drafts, and chats, is left out of the list we fetch, so we do not read it.
  - For mail with an auto-submitted, bulk, unsubscribe, or mailing-list header, mail from a no-reply, notification, or bounce address, and calendar invitations and notifications, **we read only the headers (sender, recipients, subject, date, message ID, and the markers used for filtering) and never fetch the body.** Two exceptions: mail is not filtered because of an unsubscribe or mailing-list header if the sender's address or the group address is on the same domain as your company (company accounts only), and email you sent is filtered by these rules only if it has an auto-submitted header.
- **What we store:** the remaining emails, **one by one** (emails in the same conversation are stored separately): the body (including quoted earlier messages that came with the email; the first 20,000 characters, and anything longer is cut), subject, people involved (sender, recipients, CC), date, and original link (a Gmail address that opens the conversation the email belongs to). We do not store filtered email. To avoid reading the same email again, we keep the identifier and received time of emails we imported or filtered in the connection's information until the import has moved more than an hour past that time (they stay while importing is paused because the connection expired or AI consent was withdrawn, and they are deleted immediately when you disconnect). We add up, in the connection's settings, how many emails were filtered by each rule and how many were imported (no text or addresses).
- **Access:** `gmail.readonly` (read email) and `openid` · `email` (to identify the Google account you connected, show its address on the Connections screen, recognize you in the source text, tell same-company mail apart from other mail, and make the original link open that account's mailbox). We never send, delete, or relabel email.

### Slack

- **How we receive messages:** through the Slack Events API, Slack sends our server messages posted in conversations you belong to. We never bulk-download conversation history.
- **What we keep:** direct messages with you, group DMs you are in, and channel messages that mention you or that you wrote, plus messages in threads you wrote in or were mentioned in. **Channel messages that match none of these are discarded on arrival and never stored.** We do not fetch messages posted before you connected.
- **What we store:** kept messages wait in a queue; once a conversation has been quiet for 30 minutes we group them by conversation or thread and store them as source text, and once processing finishes we clear the text in the queue. Source text includes the grouped messages, sender names, times, and original links. When a task is created, the message line it came from (the evidence quote). Your Slack workspace name, address, and identifier; the Slack user identifiers and names of you and the people you talk with; and conversation names (channel names and who a DM is with). Source body text is deleted 90 days after it is stored (section 5).
- **Access:** user-token conversation read scopes (`im:history`, `mpim:history`, `channels:history`, `groups:history`), conversation info (`im:read`, `mpim:read`, `channels:read`, `groups:read`, to know channel names and who a DM is with), and user names (`users:read`). We install no bot, and we never send or edit messages.
- **When you disconnect or remove the app:** when you disconnect in the app, we ask Slack to revoke the token; when you remove the Taskforce app or revoke its access in Slack, we delete the stored token. In both cases we immediately delete the body text, title, and people involved of the Slack source text, the quote text of claims, Jev judgment records, queued messages, tracked threads, and name information, and each evidence quote is replaced by a removal note. If Slack fails to tell us the app was removed, a daily token check deletes the same data within a day. What remains: tasks (title, due date, status, counterpart), change history, the embedding used to find similar tasks (a numeric vector), and original links. If you removed the app in Slack, the connection record (workspace name, address and identifiers, and your Slack user ID) remains in a "revoked" state until you disconnect it in the app.
- **Commitments:** we do not use data received from Slack to train any AI model, including large language models (LLMs); we do not use one workspace's data for another workspace or a third party; and we do not bulk-export it.

## 4. What we send to external AI

Taskforce uses external AI models to find tasks in source text, decide whether a new task is the same as an existing one, find similar tasks, and write drafts you start. Drafts are only saved in the app; we never send them to their recipients or write them to a connected service.

### What we send

- Source text from connected services (body, title, date) and the names and email addresses of the people involved
- Text you paste in (body and title)
- Your display name, aliases, and email addresses, so the model can recognize you in the text
- Titles and evidence quotes of existing tasks, to compare with newly found candidates
- (Tasks you add yourself, only after you have given AI data consent) its title and, if you picked one, the source line, used to find similar tasks
- (When you use Ask) your question and the related tasks and evidence quotes (including draft records)
- (When you start a draft) what you asked for; the task's title, status, owner, due date, and counterpart name; its evidence quotes with the surrounding excerpts of source text; those sources' type, title, date, and the names and email addresses of the people involved; your name (or the part of your account email before @); and the instructions and titles of drafts already written for the same request. **We do not send source text from Slack or its evidence quotes** (for tasks from Slack, the task's own title, status, owner, due date, and counterpart name are still sent)

### Who receives it, and under what conditions

- Every AI request goes through **OpenRouter, Inc.** (USA) to a model provider. Recipients and countries are listed in the table in section 7.
- Every request requires "route only to providers with Zero Data Retention" and "do not use providers that collect or train on data". If no provider meets these conditions, the request fails; we never retry with weaker conditions.
- Prompt logging is turned off on our OpenRouter account. OpenRouter keeps a usage record for each request with no content (model, token counts, cost, and similar), and we look up that record by request identifier to confirm what a draft cost.
- **With your own OpenRouter key (Lifetime),** requests run through your OpenRouter account. The two conditions above and the fixed provider list still apply; if your OpenRouter account settings prevent them from being met, the request fails. Account-level OpenRouter settings such as prompt logging cannot be turned off by a request, so they are yours to choose, and the usage records with no content are kept in your OpenRouter account.
- Nothing we send is used to train any AI model, ours or anyone else's.

### Conversations with agents

- Our server does not send the messages and replies you exchange with an agent to external AI. What an agent sends to a model provider under your account is not sent by us, so it follows that service's terms and policy rather than the promises in this section (see "Agents").
- However, if a message you send to an agent creates a new task, that task (its title is the first line of the message, and its evidence quote is the message text) is handled like any other task. After you consent, it may be used in the task comparison and similar-task search (embeddings) under "What we send" above, and as material for a draft you start.

### When you talk to Taskforce

For each reply, we send the following through OpenRouter. The recipients and conditions are the same as above (fixed providers, no data retention, no training).

- **Intent judgment (Jev):** your current message in full, the first 600 characters of the previous reply, and the titles of open suggestions. When we check a memory candidate: the memory sentence, the quote, the message quoted, and the previous memory sentence. When we judge a request to move, merge, or delete tasks: the message text and task numbers (#) only; we do not send titles or project names.
- **Producing the reply (the consultation model):** the project name, your current message, up to 20 earlier messages (each up to 1,500 characters), up to 50 open tasks (title, owner, due date, counterpart name, whether it needs confirmation), up to 20 tasks finished in the last 7 days, up to 40 memories (sentence, type, subject, kind of source, scope, time said), and up to 12 sources (title, date, excerpts). An excerpt is either the evidence quote of a task with the text around it (about 700 characters) or a project chunk (up to 1,400 characters). The evidence quotes and surrounding text of sources taken from connected services can include text that came from Slack (quotes deleted when you disconnect Slack are left out). We do not use Slack source text in project chunks.
- **Embeddings:** the chunk text when we make source chunks, and, in a conversation that has a project, your current message in full to find similar chunks.
- A new task created from a memory or a conversation follows "What we send" above, like any other task.

### Consent and withdrawal

- Before you connect your first service, the app shows you this information and asks for your consent. **If you do not agree, the server does not send or process source text from connected services or text you paste in, and does not write drafts.**
- You can withdraw consent at any time in app → Settings → Privacy & AI Data. After you withdraw, we stop importing new source text from your connected services and do not send source text to AI, so no new tasks are created from your sources, and a draft in progress stops before its next AI request. Existing tasks and drafts remain; to delete them, delete your account.
- "Hand off to AI" packages a task's context as text and shows it in the app. If you paste that text into another AI tool, you are doing so yourself; we do not send it.
- Agent conversations that go through our server (sending or resending a message) also work only after you give this consent. If you withdraw it, you cannot send new messages.
- AI calls for conversations with Taskforce and for source chunks also need this consent, and we check it again right before each call. After you withdraw, they stop with the next call, and the conversations, memories, and chunks already stored remain.

## 5. Retention and deletion

### Retention

| Information | Retention |
|---|---|
| Account, profile, sign-in sessions | Until you delete your account |
| Connections and access tokens | Until you disconnect or delete your account |
| Source text from connected services and pasted source text (body text) | **90 days after it is stored.** After 90 days we delete only the body text; the row, title, original link, people involved, and processing result remain until you delete your account (they remain after you disconnect). **For Slack, when you disconnect or remove the app,** we delete the body text, title, and people involved right away |
| Jev judgment records (including candidate quotes) | 90 days after they are stored. For Slack source text, right away when you disconnect or remove the app |
| Tasks, evidence quotes (including draft records), change history, embeddings | Until you delete your account. Evidence quotes remain even after the source body text is deleted, except that evidence quotes from Slack are deleted when you disconnect or remove the app (the tasks and embeddings remain). A task you delete in the app disappears from your list but is kept in a "deleted" state so we can calculate the error rate |
| Draft body text, what you asked for, and the instructions, suggested recipients, and questions the AI set while writing the draft | **90 days after they are stored.** After 90 days we delete only this text; the draft title and run records remain until you delete your account. If the draft run is still in progress at that point, we delete what you asked for and the instructions, suggested recipients, and questions as soon as the run ends. The same applies if you delete the task |
| Run records (status, outcome type, times, model, error type, status changes) | Until you delete your account |
| AI usage records and credit grant and usage records | Until you delete your account |
| Plan and payment records | Until you delete your account. The retry inbox up to 7 days; a pseudonymous checkout retry record until 7 days after its expiry ("Plans and payment data" above). Lemon Squeezy's transaction records follow its retention obligations |
| OpenRouter key (Lifetime) | Until you remove it, a Lifetime refund is confirmed, or you delete your account |
| Agent conversations (messages, replies, questions, approval requests), agent sessions, and file records | Until you delete your account. We do not delete them automatically, and there is not yet a screen to delete an agent conversation one by one (see "Agents" above, and section 11). The source text of the "Taskforce conversation" source created by a message you send to an agent is deleted 90 days after storage, like other source text |
| Agent delivery request records (no text); records of file paths kept so that two jobs do not edit the same file at once | 30 days after they finish or are released. Path records for a collision not yet resolved are kept until it is resolved |
| Other Claude Code sessions list (titles and so on) | A session that disappears from the list is deleted the next time this Mac uploads. If this Mac stops uploading, 14 days after the last upload. Immediately when you disconnect this Mac; the app clears it when you sign out |
| Stored Claude desktop conversations | **Until you delete them or delete your account.** We do not delete them automatically. When you delete, the conversation (messages, tool names, title) is deleted right away. So that the same text is not saved again, identifier values with no text remain and may stay until you delete your account (the oldest are removed first once there are more than 10,000 per user) |
| Agent information stored on this Mac | Finished delivery requests and events that could not be uploaded: 7 days; the full text of replies that were cut short when uploaded: 30 days; up to 50 MB per account. The working-folder list and per-session state: until you delete your account on this Mac (signing out does not delete them, and they can remain if you delete the app without signing out). The device secret is deleted when you use Disconnect this Mac or delete your account, and the secret key for the session list when you sign out or delete your account |
| Queued Slack messages (before grouping into source text) | 3 days after they arrive. Once grouped into source text and processed, the text is cleared, and only a marker (conversation, message, and sender identifiers) is kept until 3 days after arrival so the same message is not received twice. Right away when you disconnect or remove the app |
| Tracked Slack threads (identifiers of threads you wrote in or were mentioned in) | 14 days after the last activity. Right away when you disconnect or remove the app |
| Slack name information (user and conversation names) | Until you disconnect or remove the app (a name older than 7 days is re-read when it is needed again) |
| Conversations with Taskforce (messages, replies, evidence quotes, suggestions) | Until you delete your account. We do not delete them automatically, and there is not yet a screen to delete a conversation (section 11). The evidence quotes, source titles, and links in a reply are replaced with a placeholder or blanked when you disconnect Slack or the source row is deleted (the 90-day retention cleanup leaves the quotes in place) |
| Memory | Until you delete your account. A forgotten memory and the older text before an edit disappear from the screen and from replies but remain as history |
| "Address that identifies you" | Until you disconnect the service (for Slack, also when you remove the app), or until you delete your account |
| Projects and which project a task belongs to | Until you delete your account (archiving does not delete) |
| Source chunks (text + vectors) | Deleted together with the source text (90 days after storage). Chunks from Notion or Google remain after you disconnect, as the source text does. Chunks of a source whose access we have lost are not deleted, only left out of search |
| Event records, review suggestions, return summary state | Until you delete your account. We do not delete them automatically |
| Usage records | Until you delete your account |
| Push device tokens | Until you sign out, Apple reports the token invalid, or you delete your account |
| Task list stored on your device | Until you sign out on that device or delete your account (if the account is deleted on another device, the copy is deleted the next time this device's app reaches our server). On a Mac, the list can remain on the computer if you delete the app without signing out |
| Server request records (Vercel) | 1 day |
| Database and authentication request records (Supabase) | 1 day |
| Authentication email content and delivery records (Resend) | Default retention of 30 days (Free, Pro, and Scale). Resend separately retains backups for 7 days. Deleting your Taskforce account does not immediately delete these records. Verification codes expire after 10 minutes |
| AI requests (OpenRouter and model providers) | Request content not stored; only while the request is processed (OpenRouter keeps a usage record with no content, section 4) |
| Support email | Identifiable content deleted within 90 days after the request is closed |

No law currently requires us to keep any of this information longer. If one does, we will list the legal basis and items here and store them separately.

### How we delete

- **Account deletion:** app → Settings → Delete Account (Mac: Settings → Account → Delete Account). When the server deletes your authentication account, rows in every table linked to it (profile, connections and tokens, source text, tasks, evidence, history, judgment records, usage records, device tokens, drafts and run records, AI usage and credit records, plan and payment records, OpenRouter key, agent device, conversation, session, and file records, the other Claude Code sessions list, stored Claude desktop conversations, conversations with Taskforce, memories, projects, source chunks, event records, review suggestions, and return summary state) are deleted in the same request. The app also deletes the task list stored on that device and the agent records folder and device secret on this Mac; on your other devices, the stored list is deleted the next time the app on that device reaches our server.
  When you delete your account, we also ask Apple to revoke your Sign in with Apple tokens, ask each connected service to revoke its tokens, and, if you signed in with Google, ask Google to revoke that sign-in access. For accounts that sign in with Apple, we ask you to confirm with Apple once more (on a Mac, in a browser window) before we request revocation. If you cancel, or the confirmation or revocation fails, Taskforce may remain linked in your Apple Account, but your account is still deleted. If you cancel or the confirmation fails, the app shows how to remove Taskforce in your Apple Account settings.
- **Automatic deletion of source text and drafts:** a job runs daily and deletes the body text of source text stored 90 days ago, and deletes Jev judgment records stored 90 days ago. The same job deletes draft body text, what you asked for, and the draft instructions, suggested recipients, and questions stored 90 days ago (if the draft run is still in progress at that point, it deletes what you asked for and the instructions, suggested recipients, and questions the first time it runs after the run ends), and deletes queued Slack messages that arrived 3 days ago and Slack threads with no activity for 14 days.
- **Disconnecting or removing Slack:** when you disconnect Slack in the app or remove the app (or revoke its access) in Slack, we delete that connection's Slack source body text, titles, and people involved, evidence quotes, claim quote text, Jev judgment records, queued messages, tracked threads, and name information at once (Slack in section 3). A daily check of Slack tokens runs the same deletion within a day even if we were not told the app was removed.
- **Disconnecting an agent and deleting stored conversations:** you can delete a stored Claude desktop conversation one at a time in the Mac app under Sessions → Saved chats, or all at once with Delete all saved chats under Settings → Account, and what you delete is removed from our server right away. When you disconnect this Mac (Settings → Connections → Your agents → Claude Code → Disconnect this Mac), the Mac's name and the other Claude Code sessions list are deleted from our server, but agent conversations and Claude desktop conversations already stored remain.
- **No app database backups:** we keep no app database backups, so data deleted from that database does not remain in a backup. The separate retention and backups for Resend authentication emails follow the table above. If we start keeping app database backups, we will add their retention period to this policy first.
- **Logs:** server and database request records are deleted automatically by each provider after the periods above. These records do not contain source text.
- Electronic files are deleted so they cannot be recovered. We do not create paper records.

## 6. Disclosure to third parties

We do not provide or sell your personal information to third parties or use it for advertising. The only exception is a lawful request by an authority under applicable law.

## 7. Processors and international transfers

### Processors

| Processor | Service |
|---|---|
| Vercel Inc. | Server operation (API, scheduled sync), website hosting |
| Supabase Pte. Ltd. (storage infrastructure: Amazon Web Services) | Database, sign-in and authentication, generating authentication email |
| Plus Five Five, Inc. (Resend) | Sending authentication email and recording delivery outcomes |
| OpenRouter, Inc. | Routing AI requests |
| Model providers (through OpenRouter; see table below) | Running AI models |
| Apple Inc. | Delivering push notifications (APNs) |
| Google LLC (Google Workspace) | Receiving and storing support email |
| Lemon Squeezy (merchant of record) | Selling and processing plan payments, tax, receipts, refunds, subscription management pages |

We rely on each processor's data processing agreement and confirm that each processor protects personal information at least as well as this policy describes. If a processor changes, we update this policy first. Agent services you connect and use yourself (for example, Anthropic's Claude Code) are not something we entrust to them, so they are not listed in this table (see "Agents").

### International transfers (PIPA Art. 28-8)

Our server and database are outside Korea. All transfers happen over the network (TLS-encrypted) at the time you use the service.

| Recipient (contact) | Country | Items | Purpose | Retention |
|---|---|---|---|---|
| Vercel Inc. (privacy@vercel.com, 440 N Barranca Ave #4133, Covina, CA 91723, USA) | Australia (Sydney, server execution), USA (request records and management systems) | Everything that passes through the server (section 1), server request records | Server operation, website hosting | While the request is processed; request records 1 day |
| Supabase Pte. Ltd. (privacy@supabase.com) | Australia (Sydney, AWS ap-southeast-2) | All items in section 1 except support email, the task list stored on your device, and Resend delivery records | Data storage, sign-in and authentication | Until account deletion; request records 1 day |
| Plus Five Five, Inc. (Resend, support@resend.com) | Japan (Tokyo, sending), USA (email content and delivery record storage) | Recipient email address, subject, body containing a verification code, sending time and delivery outcome | Sending sign-in and other account verification email | Resend retention in section 5 |
| OpenRouter, Inc. (privacy@openrouter.ai) | USA | What we send (section 4). For Lifetime, your OpenRouter key (to authenticate requests to your account, and to check the key can be used when you save it) | Routing AI requests | Request content not stored (only while the request is processed). Usage records with no content are kept under OpenRouter's policy |
| Together AI, Inc. (privacy@together.ai) · Fireworks AI, Inc. (privacy@fireworks.ai) · Deep Infra Inc. (policy@deepinfra.com, 2625 Middlefield Road #460, Palo Alto, CA 94306, USA) (through OpenRouter, finding tasks in source text, writing drafts, and producing conversation replies) | USA (based on headquarters; the providers do not publish where the request is actually processed) | What we send (section 4) | Running AI models (source analysis, drafting, and conversation replies) | Not stored (Zero Data Retention) |
| Microsoft Corporation (Azure, through OpenRouter, embeddings; privacy contact: go.microsoft.com/fwlink/?linkid=2126612, One Microsoft Way, Redmond, WA 98052, USA) | USA (based on headquarters) | The part of what we send (section 4) used to find similar or related tasks (titles and evidence quotes of new candidates, tasks you add yourself, and existing tasks; your Ask questions; the text of source chunks; your current message in a conversation) | Running AI models (embeddings) | Not stored (Zero Data Retention) |
| TypeSafe AI, Inc. (through OpenRouter, judgment; privacy@typesafe.ai, 255 California St, Suite 1300, San Francisco, CA, USA) | USA (address in TypeSafe's terms of use) | What we send (section 4, including the inputs for judgment in conversations), except what we send when you start a draft | Running AI models (judgment) | Not stored (Zero Data Retention) |
| Apple Inc. (One Apple Park Way, Cupertino, CA 95014, USA · apple.com/legal/privacy/contact) | USA | Push device token, notification content (for review and due-date notifications, task identifiers and a short generic phrase such as "Review" or "Due today", plus the number of tasks for due-date notifications; for a connection-expiry notice, only a short generic phrase containing the service name, such as "Reconnect Gmail to keep syncing.", and no task identifier; task titles are never included) | Delivering push notifications | Under Apple's policy |
| Google LLC (1600 Amphitheatre Parkway, Mountain View, CA 94043, USA) | USA and other countries where Google has data centers | Email address and content of support email | Receiving and storing support email | 90 days after the request is closed |
| {{Lemon Squeezy contracting entity and privacy contact}} | USA and other countries named in Lemon Squeezy's policy | At checkout: checkout reference, selected plan and price variant, whether a trial or first-month discount applies (you enter your email, billing details, and payment information on Lemon Squeezy directly) | Selling and processing plan payments | Under Lemon Squeezy's retention obligations and policy |

- **Ground for transfer:** entrustment and storage needed to perform our agreement with you, with the items above disclosed in this policy (PIPA Art. 28-8(1)(3)). Sending to external AI (section 4) additionally requires your in-app consent.
- **How to refuse, and the effect:** because our server and database are outside Korea, we cannot provide the service if you refuse international transfer. To refuse, stop using the service and delete your account. To refuse only the transfer to external AI, do not give, or withdraw, AI data consent. In that case we do not process source text from your connected services or text you paste in, no tasks are created automatically, and drafts cannot be written.

## 8. When we look at your source text

We (the operator) look at your source text, tasks, drafts, agent conversations, stored Claude desktop conversations, conversations with Taskforce, and memories only:

1. When you ask us for help with a specific source, task, or draft, and only within that request
2. When it is strictly necessary to respond to a security incident or outage
3. When required by law

If we want to look at a source to analyze why a task was wrong or missed, or to use it as evaluation data, **we first tell you which source and why, and ask for your consent.** Evaluation data is used only after information that identifies people is removed.
When we look at a source, draft, or conversation, we record the date, what we looked at, and why.

## 9. Security measures

- **Administrative:** only one person, the privacy officer, handles personal information. We follow the access rules in section 8 and record every access. Operator accounts (server, database, code repository, Apple, Google, Slack, Notion, OpenRouter) use two-factor authentication.
- **Technical:**
  - All traffic is encrypted with TLS.
  - The database runs on hosting that encrypts data at rest (AWS). Access tokens for connected services are encrypted again with a separate key (AES-256-GCM) that exists only in the server's environment variables.
  - Every table has row-level security (RLS), so you can read only your own data. The token table cannot be read by the app, only by the server. Only the server writes tasks, evidence, and history.
  - The server verifies the signature of your sign-in token on every request.
  - A Lifetime user's OpenRouter key is also encrypted with a separate key (AES-256-GCM), different from the one for connected-service access tokens, and the app cannot read that table. We do not receive card numbers or other payment-method details ("Plans and payment data" above).
  - Server logs never contain source text, tokens, authorization codes, or OpenRouter keys.
  - Lock-screen notifications never include task titles.
  - Agents: this Mac's device secret stays in the Keychain and the server stores only its hash. Your messages reach the agent only as input to a process on this Mac and are not left in the command line, the environment, or logs (what the agent keeps in its own records is separate); the agent is started with only four environment variables (HOME, USER, LANG, and PATH). The server does not store the commands it receives for a tool-use decision (the up-to-300-character command stored when approval is requested is the one described in "Agents"), keeps file paths only in the path records described there, and its logs contain result codes only.
- **Physical:** the server and database run in our processors' data centers (Vercel, Supabase/AWS) under their physical security. We run no servers of our own.
- **Breach response:** if personal information is leaked, we notify you and the relevant authorities within 72 hours of learning of it and take steps to limit the harm.

## 10. Cookies and similar technologies

- The app does not use cookies. Your sign-in session is stored in the device Keychain.
- The website (www.taskforcelabs.dev) has no analytics, no advertising tools, and no cookies.
- Our internal admin screens use a cookie only for the operator's sign-in. Users do not use these screens.
- Lemon Squeezy's checkout and subscription management pages use their own cookies under Lemon Squeezy's policy.

## 11. Your rights and how to use them

You can ask to access, correct, delete, or stop the processing of your personal information, and you can withdraw consent, at any time.

| To do this | How |
|---|---|
| See your tasks, evidence, drafts, and agent conversations | Directly in the app |
| Change your name or aliases | App → Settings → Profile (Mac: Settings → Account) |
| Edit or delete a task | Directly in the app |
| Disconnect a service | App → Settings → Connections → Disconnect. You can also remove access in each service (Google: myaccount.google.com/connections; Notion: Settings → Connections; Slack: your workspace's app management). For Slack, disconnecting also deletes the text we got from Slack (your tasks remain) |
| Withdraw consent to AI transfer | App → Settings → Privacy & AI Data |
| Disconnect this Mac's agent | App → Settings → Connections → Your agents → Claude Code → Disconnect this Mac |
| Delete stored Claude desktop conversations | Mac app → Sessions → Saved chats to open and delete one at a time; Settings → Account → Delete all saved chats to delete all |
| See, confirm, edit, or forget memories | Mac app → Settings → Account → Remembered (a forgotten memory remains as history; to delete it, use the next row) |
| Delete agent conversation and session records, conversations with Taskforce, forgotten memories, and projects | Delete your account, or email privacy@taskforcelabs.dev (there is not yet a screen to delete them one by one) |
| Delete all your data | App → Settings → Delete Account (Mac: Settings → Account → Delete Account) |
| Any other access, correction, deletion, or restriction request | Email privacy@taskforcelabs.dev |

- We answer email requests within 10 days. We may ask you to write from your account email so we can confirm it is you.
- A legal representative or someone you authorize can make a request; we will confirm the authorization.
- We may refuse a request where the law allows it, and we will tell you why.

## 12. Automated decisions

Taskforce uses AI to find tasks, due dates, and owners in your sources and builds your list from them, and when you start a draft, writes it and saves it in the app (it is not sent to its recipients). This helps you organize your own work; it is not a decision that significantly affects your rights or obligations.
We ask you to confirm owners and due dates we are unsure of, and every task the AI creates carries the quote it came from (except quotes deleted when Slack is disconnected, section 3). You can correct or delete any task at any time and ask us to explain how it was produced.
In conversations with Taskforce, the AI judges your intent from what you say and, when it is confident, saves what you said as a memory or moves a task to another project. It creates a new task, or deletes or merges tasks, only after you confirm.

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

For information Taskforce receives through Google APIs (Google sign-in information, Calendar events, Meet transcripts, Gmail messages), we make these commitments:

> Taskforce's use of information received from Google APIs will adhere to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements.
>
> The use of information received from Google Workspace scopes will adhere to the [Google User Data Policy](https://developers.google.com/workspace/workspace-api-user-data-developer-policy), including the Limited Use requirements.

Specifically:

- We use Google data only for features visible in the app: finding and showing the work you committed to, linking sources from the same meeting, and writing drafts you start.
- We do not use Google data for advertising, credit assessment, or data sales, and we do not transfer it to third parties such as advertising platforms or data brokers.
- We do not use Google data to create, train, or improve generalized AI or machine learning models. We send it to external AI models only when needed to provide these features, only after you consent in the app, and only to providers that keep no data (section 4).
- No person reads Google data, except when you have explicitly agreed to let us view specific data, when necessary for security purposes (such as investigating abuse), when necessary to comply with applicable law, or when the data is aggregated so that no one can be identified and used for internal operations.
- We transfer Google data only to provide these features, for security, to comply with law, or as part of a merger or acquisition with your explicit prior consent.

## 16. Users in the EU and UK

The beta is not offered to people who live in the European Economic Area (EEA, including the European Union) or the United Kingdom (Terms of Use, section 4.3). We do not advertise there, and the app is not made available in those App Store regions. If the EU or UK General Data Protection Regulation (GDPR, UK GDPR) still applies to you:

- **Controller:** 태스크포스 (Republic of Korea), privacy@taskforcelabs.dev. We have not appointed a Data Protection Officer.
- **Legal bases:** providing the service: performance of a contract (Art. 6(1)(b)); sending to external AI: consent (Art. 6(1)(a)) and performance of a contract; service metrics, security, and processing other people's information in your sources: legitimate interests (Art. 6(1)(f)). Our legitimate interest is finding your own commitments in the work sources you connect and, when you ask, writing a draft for that work, and we use the information for nothing else.
- **International transfers:** your information is transferred outside the EU and UK (to Korea, Australia, the USA, and others). Our processors' data processing agreements include the European Commission's Standard Contractual Clauses (SCCs) or equivalent safeguards. You can request a copy at the contact above.
- **Your rights:** access, rectification, erasure, restriction, portability, objection, and withdrawal of consent (without affecting the lawfulness of processing before withdrawal). You have the right to lodge a complaint with the supervisory authority in the EU member state or the UK where you live.
- **Whether you must provide data:** account information is needed to use the service. Connecting services and consenting to AI transfer are optional, but without them no tasks are created automatically and drafts cannot be written.
- **Automated decisions:** we make no decisions with legal or similarly significant effects under Art. 22 (section 12).

## 17. Changes to this policy

- We announce changes in the app and on this page at least 7 days before they take effect. Changes that are less favorable to you, such as new items, purposes, or recipients, are announced 30 days in advance, and we ask for consent again where needed.
- Previous versions remain available on this page.

Change history

- Beta 1.7 (effective {{effective-date-1.7}}, [view previous version](https://www.taskforcelabs.dev/en/privacy/beta-1.6)): We added an "Agents" section about agents you connect yourself in the Mac app (such as Claude Code): registering this Mac; storing the messages, replies, and file records you exchange with an agent on our server and how long we keep them; uploading the titles and other details of the other Claude Code sessions on this Mac to our server; storing the identifier of a session you resume when you resume one that was started outside Taskforce; and storing messages sent to a session open in the Claude desktop app, with the replies and tool names, until you delete them or delete your account, with deletion available in the app. We also state that what an agent sends to a model provider under your account is not sent by us and so is outside the AI provider promises. We also added a "Conversations with Taskforce, memory, and review" section: storing conversations with Taskforce (messages, replies, evidence quotes) on our server and what we send to external AI during a conversation (judgment, consultation, embeddings); memory and projects; source chunks and search; event records; review and the return summary; and how long we keep each (conversations and memories have no delete screen and stay until you delete your account, and a forgotten memory stays as history).
- Beta 1.6 (effective {{effective-date}}, [view previous version](https://www.taskforcelabs.dev/en/privacy/beta-1.5)): We added the Pro and Lifetime plans and payment. Lemon Squeezy processes payments as merchant of record. We describe what we send Lemon Squeezy at checkout (checkout reference, plan, price variant, whether a trial or discount applies) and the plan and payment records we store and how long we keep them, and we added Lemon Squeezy to the processor and international-transfer tables. A Lifetime user's OpenRouter key is encrypted, stored, and used only for that user's AI requests; we still require Zero Data Retention routing, but that OpenRouter account's settings, such as logging, are the user's. AI usage is now also used to apply the Pro fair-use limit. You can now sign in with Apple on a Mac too (you sign in in a browser window, and Taskforce's server only passes the result to the app). You can now add another sign-in method to your account. Added email-code sign-in and the data handled by Resend, including sending from Tokyo, storage in the United States, and retention.
- Beta 1.5 (effective 2026-10-07, [view previous version](https://www.taskforcelabs.dev/en/privacy/beta-1.4)): We corrected the Gmail OAuth status: Gmail is offered in Production without test-user registration; Google has not verified the gmail.readonly scope, so authorization shows an unverified-app warning and is limited to 100 users over the app's lifetime. Newly issued Production refresh tokens do not have Testing mode's seven-day expiration, though existing connections may still need to be reconnected.
- Beta 1.4 (effective 2026-10-04): When you start a draft for a task (such as an email or document), we now send that task and excerpts of its evidence sources (excluding source text from Slack) to the same external AI providers used for source analysis, write the draft, and save it in the app. We do not send drafts to their recipients. Drafts, run records, AI usage, and credits (granted by us free of charge; no purchases) are now listed among the information we process, with their retention periods (draft body text, what you asked for, and the instructions, suggested recipients, and questions the AI set: 90 days after they are stored; if the draft run is still in progress at that point, what you asked for and the instructions, suggested recipients, and questions are deleted as soon as it ends). We also describe that OpenRouter keeps usage records with no content and that we look them up; that we record when a source is closed as failed; and that the app stores the last task list (title, due date, status) on your device for each account so it can show it until a fresh list arrives (for example, while offline), and deletes it when you sign out or delete your account (if the account is deleted on another device, the next time this device's app reaches our server). We also state that the titles and picked source lines of tasks you add yourself, and your Ask questions, also go to the embedding provider (Microsoft) to find similar tasks. AI data consent is now changed in Settings → Privacy & AI Data, and the paths for your profile, disconnecting a service, and deleting your account now match the app's Settings screen.
- Beta 1.3 (effective 2026-10-02, [view previous version](https://www.taskforcelabs.dev/en/privacy/beta-1.3)): Text you paste into the Mac launcher (body and title) is now listed among the information we process. Like source text from connected services, it is sent to external AI only after you give AI data consent, and its body text is deleted 90 days after it is stored. We also describe what happens when you delete an account that signs in with Apple and you cancel the Apple confirmation, or the confirmation or revocation fails.
- Beta 1.2 (effective 2026-09-30, [view previous version](https://www.taskforcelabs.dev/en/privacy/beta-1.2)): You can now sign in with Google. At sign-in we receive your Google account identifier, email address, name, and profile photo URL (and your organization's domain for Google Workspace accounts), and when you delete your account we ask Google to revoke that sign-in access.
- Beta 1.1 (effective 2026-09-30, [view previous version](https://www.taskforcelabs.dev/en/privacy/beta-1.1)): The Gmail section now matches how the service works (which mail is skipped and why, one message stored at a time, the IDs and received times of fetched or skipped mail and per-reason counts, and the account-identification permissions). When a connection expires, we send one reminder to reconnect and keep a record of connections, expirations, and reminders. Baseten was removed from the source-analysis providers.
- Beta 1.0 (effective 2026-09-29): [View previous version](https://www.taskforcelabs.dev/en/privacy/beta-1.0)

This policy takes effect on {{effective-date-1.7}}.
