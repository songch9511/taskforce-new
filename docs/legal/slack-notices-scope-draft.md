# Review copy for expanded Slack intake

Draft only; no published policy/version/date has been changed.

## Connection disclosure
- DMs and group DMs, including messages from apps and bots
- Channel messages you write or are mentioned in, and those threads
- Channel-wide mentions visible to your Slack account
- New messages only. Taskforce never sends anything.

## Slack scope paragraph - Korean
남기는 메시지: 이용자와의 DM, 이용자가 속한 그룹 DM, 이용자가 썼거나 이용자를 직접 언급한 채널 메시지와 그 스레드의 메시지, 그리고 연결한 이용자 계정에 보이는 채널 전체 언급(@channel, @here, @everyone)이 포함된 메시지입니다. 이 범위에는 다른 앱이나 봇이 보낸 메시지도 포함됩니다. 채널 전체 언급만으로 그 스레드 전체를 추적하지는 않습니다. 이 범위에 해당하지 않는 채널 메시지는 받는 즉시 버리고 저장하지 않습니다. 연결 전의 대화 기록은 가져오지 않습니다. 메시지를 받았다는 사실만으로 이용자의 할 일로 확정하지 않으며, 실제 해야 할 일과 담당을 별도로 판정합니다.

## Slack scope paragraph - English
What we keep: direct messages with you, group DMs you are in, channel messages you wrote or that directly mention you and messages in those threads, and channel-wide mentions (@channel, @here, or @everyone) visible to your connected Slack account. These may include messages from other apps or bots. A channel-wide mention alone does not cause us to track the entire thread. Other channel messages are discarded on arrival and never stored. We do not fetch conversation history from before you connected. Receiving a message does not by itself establish that its tasks belong to you; we separately assess the action and its owner.

## Release alignment
Current native Connections.swift and published-policy source describe only personal mentions, own messages, and tracked threads. Before enabling expanded broadcast collection in production, align the bilingual published scope and native pre-connection disclosure with the final implementation. Repository policy publication/version/notice workflow is docs/legal/README.md + docs/go-live/runbook.md. No activation date is assumed in this draft.
