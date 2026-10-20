# 결제 켜기 — Pro · Lifetime (2026-10-09 가격)

계약: `handoffs/oa-billing-contract.md`(확정 장이 본문보다 이긴다). 이 문서는 서버(PR-A)와 BYOK 키 보관(PR-B)이 끝난 상태의 운영 절차다. Mac 화면(PR-C), 약관 · 처리방침(PR-D)이 나오면 해당 줄을 채운다.
2026-10-08 판(월 $9.99 · 연 $101.90 · 카드 없는 7일 체험 · 월 $3 한도)은 한 번도 켜지지 않았고 이 문서가 대신한다. 옛 Lemon Squeezy(LS) 테스트 상품 `1420342` · Live 초안 `1420403`과 그 변형은 다시 쓰지 않는다. 옆에 살려 두지 않는다.

**지금 상태:** 코드는 `BILLING_ENABLED`가 꺼진 채 병합되도록 만들었다. 꺼져 있으면 모든 계정이 "Beta"이고 지금과 똑같이 돈다(관리형 키, 옛 원가 안전장치). 켜는 것은 모두 사용자 몫이다(13.3의 각 단계는 승인 한 번씩).

## 1. 제안

| 항목 | 값 |
|---|---|
| Pro 월간 | $12.99/월, **첫 달 $6.99** (첫 Pro 구독만) |
| Pro 연간 | $119.88/년 ($9.99/월) |
| 체험 | 카드가 필요한 3일 무료 체험, 계정당 처음 한 번. 체험이 끝나면 첫 결제가 자동으로 된다 |
| Lifetime | $229 일시불(정가 $299, 한정 사다리). 사용자의 OpenRouter 키로 돈다(10장). `BYOK_ENABLED`가 켜져야 판다 |
| 환불 | 각 결제의 LS 시각부터 72시간 안 전액, 계정당 셀프 1회. 그 밖은 약관의 문의 메일 |
| 무료 플랜 · 크레딧 판매 | 없음. 끝나면 AI · 실행만 멈추고 목록 · 결과 · 근거 읽기는 남는다 |
| 세금 | 별도(LS 스토어 설정 그대로). 가격 · 세금 분류는 사용자가 LS에서 다시 확인한다 |
| 결제 대행 | Lemon Squeezy (Merchant of Record) |

가격 숫자는 서버 한 곳 `src/lib/billing/prices.ts`에만 있다. 앱은 `GET /api/v2/billing`의 `prices`(표시 글자)를 끼울 뿐이다. LS 대시보드 가격을 바꾸면(Lifetime 사다리 포함) 이 파일의 숫자를 같이 바꿔 배포한다.

## 2. 표면

- API(앱 → 서버, `Authorization: Bearer` 또는 쿠키 + CSRF): `GET /api/v2/billing` · `POST /api/v2/billing/checkout` · `…/portal` · `…/resume` · `…/refund`. 꺼져 있을 때 checkout · portal · resume · refund는 409 `billing_unavailable`.
- 키(BYOK): `PUT /api/v2/billing/openrouter-key {key}` · `DELETE /api/v2/billing/openrouter-key`(204). `BYOK_ENABLED`가 꺼져 있으면 PUT은 인증도 보기 전에 404이고, DELETE는 플래그와 상관없이 열려 있다(남은 키는 언제나 지울 수 있다 — 로그인과 쿠키의 CSRF 확인은 그대로). 응답에 키는 없다(상태 `{ai_key: connected}`뿐). 자세한 것은 10장.
- v1은 모양 고정: `GET /api/v1/billing`(새 상태를 옛 말로 옮겨 내림, `can_checkout` 늘 false), `POST /api/v1/billing/checkout`은 **늘 409**(옛 Mac 베타 0.1.0-beta.25–32는 "업데이트" 안내만), `portal`은 그대로.
- webhook: `POST /api/webhooks/lemonsqueezy` — 서명 · 크기 · 모드를 확인하고, 정제한 inbox에 저장한 뒤 **LS 객체를 서버가 다시 읽어** 자격을 정한다(성공 페이지 · 클라이언트 신고는 믿지 않는다). 다루는 사건 13개: `order_created` · `order_refunded` · `subscription_created` · `_updated` · `_cancelled` · `_resumed` · `_unpaused` · `_expired` · `_paused` · `subscription_payment_success` · `_failed` · `_recovered` · `_refunded`. 그 밖(`customer_updated` · `license_key_*` · `affiliate_activated`)은 200으로 받고 버린다.
- cron `/api/cron/billing`(10분마다): 만료 intent 정리 → inbox 재처리(7일) → **쓸기**(체험 · 해지 · past_due · 곧 끝나는 active · 환불 창 안 Lifetime · 풀리지 않은 환불 요청을 하루에 한 번 LS에서 다시 읽는다. 한 번에 20계정).
- 웹 결제 페이지 `/billing`은 지웠다(웹에 사용자용 화면을 만들지 않는다). 해지 · 결제 수단은 Mac의 Manage subscription ↗ 또는 LS 영수증 메일의 "My Orders"로 한다.

## 3. 상태와 접근 (서버가 정한다)

위에서부터 먼저 맞는 줄이다. 순수 함수 `planState`(`src/lib/billing/state.ts`)와 SQL `billing_plan_kind`가 같은 표를 구현하고 시험이 둘을 맞춰 본다.

| # | 조건 | 상태 | AI · 실행 |
|---|---|---|---|
| 0 | `BILLING_ENABLED` 꺼짐 | `beta`(모두) | 됨(관리형, 옛 안전장치) |
| 1 | 계정 삭제 중 | `lapsed` | 멈춤 |
| 2 | Lifetime 활성 | `lifetime` | 됨 — 사용자 키가 있어야 호출이 성공한다. 키가 없거나 폐기됐거나 열리지 않으면 `budgetFetch`가 네트워크 호출 0으로 닫고, 그래도 관리형 예약으로 가면 DB가 `byok_required`로 한 번 더 닫는다(관리형 키로 새지 않음) |
| 3 | 구독 `on_trial` ∧ 체험 끝 > 지금 | `trial` | 됨(체험 상한) |
| 4 | `active` ∧ 기간 끝 > 지금 | `pro` | 됨 |
| 5 | `cancelled` ∧ 끝 > 지금 | `cancelled` | 됨(끝까지) |
| 6 | `past_due` · `payment_pending` ∧ 지난 유료 기간 끝 + 16일 > 지금 | `past_due` | 됨(LS 재시도 동안) |
| 7 | 기존 베타 ∧ 고지 없음 또는 고지 끝 > 지금 | `beta` | 됨(옛 안전장치) |
| 8 | 구독 · Lifetime 기록 있음 | `lapsed` | 멈춤 |
| 9 | 그 밖 | `none` | 멈춤 |

- 서버가 시작하는 7일 체험 · 온보딩 24시간 유예 · 첫 동기화 체험은 걷어 냈다(옛 RPC `billing_start_trial`은 옛 프로세스 보호용으로 DB에만 남고 부르는 곳이 없다). 새 가입자는 LS 카드 체험(checkout)으로만 쓰기 시작한다.
- `past_due`의 16일은 LS 재시도 약 2주 + 여유 2일이다. 지난 유료 기간이 없는 `past_due`(체험 뒤 첫 결제 실패)는 접근이 없다. LS가 준 날짜는 접근을 늘리지 않는다.
- 끝난 뒤(`none` · `lapsed`): AI · 원천 동기화 · 새 실행은 멈추고, 수동 추가 · 목록 · 결과 · 근거 읽기는 남는다. 데이터는 지우지도 잠그지도 않는다.
- **숨은 공정 사용 상한(Q2 A):** 계정별 월 모델 원가 상한 — Pro `BILLING_MONTHLY_AI_BUDGET_USD` · 체험 `BILLING_TRIAL_AI_BUDGET_USD`. **값은 운영 env에서 정한다(이 저장소는 공개라 문서 · 예시 파일 · 코드 어디에도 적지 않는다).** 코드에 기본값이 없어 비우면 결제가 켜진 서버의 AI 경로가 멈추고, SQL은 100까지 받는다. 사용자에게 숫자를 보이지 않고, 닿으면 그달(체험 창이면 체험 끝까지) AI가 쉬며 상태 응답의 `fair_use_paused_until`로 이유를 보인다. 같은 이유로 `ai_spend_attempts`의 금액 · 토큰 열은 사용자(authenticated)가 읽지 못하게 막았다(열 단위 허용: id · user_id · endpoint · model · created_at). 운영 전체 상한 `ai_budget_policy`(하루 $5 · 누적 $50, 베타 값)는 그대로 모든 계정을 막는다 — **켜기 전에 사용자가 올린다**(13.3).

## 4. 사건 → 자격 (모든 지표 이벤트는 같은 트랜잭션 안)

| LS 사건 | 서버가 다시 읽는 것 | 반영 |
|---|---|---|
| `order_created` | 주문 | Lifetime 변형 + paid → `lifetime`, 환불 창 = 주문 시각 + 72h. Pro 변형 주문이면 구독 사건이 처리한다. 이 가게의 다른 상품이면 무시 |
| `order_refunded` | 주문 | Lifetime → `refunded`(끝, 저장된 키 삭제). Pro 첫 주문이면 구독 경로 |
| `subscription_created` · `_updated` · `_resumed` · `_unpaused` · `_cancelled` · `_expired` · `_paused` | 구독 (+ 최신 인보이스) | 상태 · 기간 · 변형(→ plan) 반영. **체험(`on_trial`)은 구독만으로 판정**(인보이스 없음) |
| `subscription_payment_success` · `_failed` · `_recovered` · `_refunded` | 구독 + 최신 인보이스 | 결제 확인된 기간만 접근을 준다. 환불된 인보이스 → 바로 끝나고, LS 구독도 취소한다(다음 갱신 막기) |

- 겹침(BL-07): Lifetime이 활성인 계정에 Pro가 오면 Lifetime이 이긴다. 서버가 그 구독을 LS에서 취소하고(환불은 하지 않는다) `billing_subscription_cancelled {by: system}`을 남긴다. 두 번째 Lifetime 주문 · 두 번째 Pro 구독은 자격을 그대로 두고 `billing_duplicate_purchase`를 남긴 뒤 webhook이 실패로 남아 **운영 검토**(환불 여부는 사람이 정한다)가 된다.
- **구매 검사는 처음 묶을 때 한 번만 한다(재검토 1).** 구독(또는 Lifetime 주문)이 계정에 처음 묶일 때 intent를 확인한다. 묶이면 intent에 `bound_subscription_id`(Lifetime은 `bound_order_id`)가, 계정에 묶은 intent와 그때의 체험 · 할인 자격(`bound_intent_id` · `bound_with_trial` · `bound_with_discount`)이 남는다. 이미 묶인 구독의 뒤 전달 · 참조 없는 다시 읽기(쓸기 · 큐)는 이 기록으로만 판단하고 **새 위반을 만들지 않는다 — 이미 묶인 구독은 자동으로 취소하지 않는다.**
  - 자동 LS 취소(`billing_duplicate_purchase` + 검토): 처음 묶을 때 확실한 조작뿐 — 체험이 없는 intent에 체험이 붙음 · 할인이 없는 intent의 첫 결제에 할인이 붙음 · 다른 사용자의 intent · 이미 쓰인 링크로 체험이나 할인이 또 붙음(이미 다른 구독 · 주문에 묶인 intent, 또는 이미 구독한 계정의 체험 — 서버는 그런 링크를 발급하지 않는다).
  - 그 밖의 어긋남(체험 · 할인 없이 이미 쓰인 intent를 다시 쓴 새 구독 · 발급되지 않은 intent · 묶인 체험의 첫 결제에 허락 없던 할인)은 구독을 두고 `billing_review_needed {reason}` 이벤트만 남긴다. 자격은 결제 사실대로 따른다. 만료되었거나 새 Start Pro로 소비된 intent라도 아직 어디에도 묶이지 않았으면 늦은 결제를 그대로 받는다.
- **운영자 쿠폰 메모:** LS 대시보드에서 운영자가 따로 만든 쿠폰(지원 보상 · 제휴 등)을 쓰면 첫 인보이스에 할인이 붙는다. 이미 묶인 구독이면 위 규칙대로 구독은 취소되지 않고, 묶인 체험의 첫 결제라면 `billing_review_needed {reason: discount_not_offered}`가 한 번 남을 수 있다 — 쿠폰을 쓴 사실을 아는 운영자는 그냥 닫으면 된다. 처음 묶는 결제 자체에 쿠폰이 붙은 새 구독(체험 없이 바로 결제, 할인이 없는 intent)은 자동 취소 대상이니, 그런 사람에게 쿠폰을 주려면 먼저 Start Pro로 intent를 받게 한 뒤 쓰게 하거나 LS에서 직접 처리한다.
- 순서 · 중복: 오래된 스냅샷은 무시하고(`provider_updated_at`), 같은 전달은 digest로 한 번만 센다.
- 놓친 사건 대비: 환불 · 다시 시작 API가 성공하면 inbox에 "다시 읽기" 항목을 넣고(10분 cron), 하루 한 번 쓸기를 한다. 1시간 넘게 풀리지 않은 환불 요청은 LS에서 확인해 환불이면 반영하고 아니면 되돌려 다시 요청할 수 있게 한다.

## 5. 환경변수

이름은 `.env.example`이 기준이다. 값은 사용자가 Vercel에 넣는다(Sensitive).

| 이름 | 뜻 |
|---|---|
| `BILLING_ENABLED` · `BYOK_ENABLED` | 켜기(정확히 `true`만). 둘은 따로다 |
| `LEMONSQUEEZY_API_KEY` · `LEMONSQUEEZY_WEBHOOK_SECRET` · `LEMONSQUEEZY_STORE_ID` · `LEMONSQUEEZY_TEST_MODE` | 그대로. 테스트와 Live는 키 · 상품 · webhook을 따로 둔다 |
| `LEMONSQUEEZY_PRO_MONTHLY_VARIANT_ID` · `LEMONSQUEEZY_PRO_YEARLY_VARIANT_ID` | **새 이름.** 옛 `…_MONTHLY_…` · `…_ANNUAL_…`은 읽지 않는다(옛 $9.99 변형 id가 남아도 쓰이지 않게) |
| `LEMONSQUEEZY_LIFETIME_VARIANT_ID` | Lifetime 변형. 비우면 Lifetime은 팔지 않는다 |
| `LEMONSQUEEZY_FIRST_MONTH_DISCOUNT_CODE` | 첫 달 할인 코드. 비우면 **첫 Pro checkout을 열지 않는다** |
| `BILLING_MONTHLY_AI_BUDGET_USD` · `BILLING_TRIAL_AI_BUDGET_USD` | 숨은 공정 사용 상한(3장). **필수, 값은 운영 env에서 정한다** |
| `USER_AI_KEY_ENCRYPTION_KEY` | Lifetime 사용자의 OpenRouter 키를 봉인하는 키(AES-256-GCM). 32바이트 base64(`openssl rand -base64 32`), **`CONNECTOR_TOKEN_KEY`와 다른 값**(바이트가 같으면 패딩 · 공백 · base64url처럼 글자 모양이 달라도 서버가 거절한다). `BYOK_ENABLED`를 켜기 전에 Vercel에 넣는다(Sensitive). 바꾸면 저장된 키가 열리지 않아 사용자가 다시 넣어야 한다(10장) |

## 6. 켜는 순서 (각 단계는 사용자 승인)

1. **법률 확정:** 변호사 검토 → 약관 · 처리방침 원문(PR-D) 병합. `BILLING_TERMS_VERSION`은 8장 0번에서 게시판 값으로 맞춘다.
2. **운영 마이그레이션 → 그 뒤 PR-A 병합(Vercel 배포).** 순서가 바뀌면 새 서버가 없는 함수를 부른다.
   ```bash
   npx supabase db query --linked --project-ref tirtdojsahotjfgdsryi -f supabase/migrations/20261129000000_billing_pro_lifetime.sql
   ```
   `db push` 금지. 새 표 · 열 · 함수는 더하기뿐이다. 옛 함수(`billing_start_trial` · `billing_apply_subscription` · `reserve_billing_ai_spend` 등)는 서명을 그대로 두고(롤백용) 서비스 역할만 부를 수 있는 채로 둔다. 하나만 고친다 — 옛 `billing_spend_window`는 Lifetime 계정이면 `byok_required`로 거절한다(롤백으로 옛 예약 함수를 쓰더라도 관리 키를 쓰지 않게). 사용자가 읽던 `ai_spend_attempts`의 금액 · 토큰 열은 앱 · 서버가 읽는 곳이 없어 읽기 권한만 걷는다. Lifetime 계정이 아직 없어 적용만으로는 지금 운영 동작이 바뀌지 않는다. 사후 검사(읽기 전용, 개수만):
   - `billing_accounts` 새 열 14개(`first_subscription_at` · `lifetime_order_id` · `lifetime_status` · `lifetime_paid_at` · `lifetime_updated_at` · `last_payment_at` · `last_invoice_id` · `refund_requested_at` · `self_refund_used_at` · `last_swept_at` · `sweep_claimed_at` · `bound_intent_id` · `bound_with_trial` · `bound_with_discount`), `billing_checkout_intents.with_trial` · `with_discount` · `bound_subscription_id` · `bound_order_id`, `ai_spend_attempts.prompt_tokens` · `completion_tokens`.
   - `billing_claim_checkout_v2` · `billing_checkout_url_v2` · `billing_apply_subscription_v2` · `billing_apply_lifetime` · `billing_record_event` · `billing_claim_refund` · `billing_release_refund` · `billing_spend_window_v2` · `reserve_billing_ai_spend_v2` · `billing_spend_summary_v2` · `record_ai_spend_tokens` · `billing_usage_tokens` · `billing_sweep_claim` · `billing_sweep_done` · `billing_mark_agent_block` · `billing_seed_legacy` · `billing_schedule_legacy_notice`가 있고 `anon` · `authenticated`에게 실행 권한이 없다(`has_function_privilege`). 새 SECURITY DEFINER 함수는 모두 `search_path = public, pg_temp`로 고정돼 있다(`pg_proc.proconfig`). `authenticated`는 `ai_spend_attempts`의 `cost_usd` · `reserved_usd` · 토큰 열을 읽지 못한다(`has_column_privilege`).
   - `metric_events_type_check`에 `billing_checkout_started` · `ai_key_saved`가 들어 있고 옛 타입도 그대로다.
3. **BYOK(PR-B)** 마이그레이션 `20261130000000` 적용 → 병합. 꺼진 채. 순서가 바뀌면 새 서버가 없는 표 · 함수를 부른다.
   ```bash
   npx supabase db query --linked --project-ref tirtdojsahotjfgdsryi -f supabase/migrations/20261130000000_user_ai_keys.sql
   ```
   `db push` 금지. 더하기뿐이다: 새 표 `user_ai_keys` · 새 함수 5개 · `rate_limit_events`의 종류 하나(`ai_key`)와 그에 맞춘 `take_rate_limit` 교체(본문은 `20261123000000` 그대로 + 종류 하나). 사후 검사(읽기 전용, 개수만):
   - `user_ai_keys`가 있고 행 수준 보안이 켜져 있으며 정책 `owner_all` 하나, `anon` · `authenticated`에게 표 권한이 없다(`has_table_privilege`가 false).
   - `ai_key_put` · `ai_key_delete` · `ai_key_mark_revoked` · `ai_key_note_spend_error` · `ai_key_note_ok`가 있고 `anon` · `authenticated`에게 실행 권한이 없다(`has_function_privilege`), 모두 `search_path = public, pg_temp`로 고정돼 있다(`pg_proc.proconfig`).
   - `rate_limit_events_kind_check`에 `ai_key`가 들어 있고 옛 종류도 그대로다.
   - 적용만으로는 동작이 바뀌지 않는다: Lifetime 계정이 아직 없고 `BYOK_ENABLED`가 꺼져 있다.
   병합 전에 `USER_AI_KEY_ENCRYPTION_KEY`를 Vercel에 넣고(5장), `BYOK_ENABLED`는 7장 V09가 끝난 뒤에만 켠다.
4. **Mac(PR-C)** 병합 → 서명 · 공증 DMG · Sparkle 게시. 서버가 꺼져 있으면 모두 "Beta"라 먼저 내도 된다.
5. **LS 테스트 모드 실측(ARCH-V08) · BYOK 실측(ARCH-V09)** — 7장 체크리스트. 결과 없이 켜지 않는다.
6. **LS Live 준비 · env 값** — 8장.
7. **시드 → 게시 · 고지(같은 날, 순서가 이렇다):** 먼저 `select billing_seed_legacy(now());`로 기존 베타를 묶는다(미래 시각은 `billing_cutoff_future`로 거절). 그 뒤에 새 약관 · 처리방침 게시 + 처리방침 `upcoming`(PR-D2) + `billing_schedule_legacy_notice(now() + 30일 이상)` + 베타 메일. **30일 시계가 여기서 시작한다.** 고지 날짜 · 메일은 사용자가 정하고 보낸다. DB가 30일 미만을 거절한다(`billing_notice_too_soon`). 고지 뒤에 가입해 나중에 시드되는 계정은 시드한 때 + 30일 이상, 그리고 모두에게 약속한 날 이후의 종료일을 받는다(열린 베타가 남지 않는다).
8. **켜기(30일 뒤 또는 변호사가 정한 날):**
   0. **`BILLING_TERMS_VERSION`을 법률 게시판 값으로 설정한다.** `src/lib/billing/prices.ts`의 값은 자리표시(`2026-10-19`)다. 새 약관이 게시된 판의 날짜로 바꾸고 배포한 뒤에만 켠다. 앱은 `GET /api/v2/billing`의 `terms_version`을 그대로 되돌려 보내므로 Mac 변경은 없다. 자리값 그대로 켜면 동의 기록이 게시된 약관과 어긋난다.
   1. `select billing_seed_legacy(now());` — 7번에서 한 번 했다. 고지 뒤에 가입한 계정이 있으면 켜기 직전에 한 번 더 돌려도 된다(위 7번의 늦은 시드 규칙). 그 시각 전에 가입했고 구독 · Lifetime 기록이 없는 계정을 기존 베타로 묶는다. 바뀐 계정 수를 돌려준다.
   2. `ai_budget_policy` 운영 전체 상한 올리기(값은 사용자). 안 올리면 하루 $5에서 모든 계정이 멈춘다.
   3. `BILLING_ENABLED=true`(Lifetime을 팔려면 `BYOK_ENABLED=true`도) → 재배포.
   4. 사후 확인: 테스트 계정으로 `GET /api/v2/billing`, 작은 실구매 1건과 환불 1건.
9. 웹사이트 가격 페이지(별도 저장소).

**되돌리기:** `BILLING_ENABLED=false`로 두면 모두 관리형 "Beta"로 돌아간다(새 표 · 열은 둔다). LS 구독은 계속 청구되므로 오래 끄면 안 된다. 끌 때 사용자에게 알린다.
- **Lifetime 계정도 같다:** `BILLING_ENABLED`가 꺼져 있는 동안 Lifetime 계정은 관리형 키로 베타 상한(옛 사용자별 한도 · 운영 전체 상한 `ai_budget_policy`) 안에서 돈다. 사용자 키는 쓰이지 않고 지워지지도 않으며, 다시 켜면 곧바로 사용자 키로 돌아간다(`src/lib/ai/budget-byok.test.ts` "결제가 꺼져 있으면 …"가 고정한다).

## 7. 실측 체크리스트 (테스트 모드, 코디네이터 + 사용자 계정)

코드가 LS 문서에서 읽어 둔 가정이다. 하나라도 어긋나면 멈추고 알린다(첫 줄은 출시를 막는다).

| # | 확인할 것 | 코드가 둔 가정 |
|---|---|---|
| V08-1 | 첫 체험 checkout(월) → `on_trial` → 체험 끝 첫 결제가 **$6.99**, 갱신 $12.99 | `once` 할인이 체험의 $0 주문이 아니라 체험 뒤 첫 유료 인보이스에 붙는다. **아니면 멈추고 사용자에게 다시 묻는다** |
| V08-2 | `checkout_data.discount_code`가 칸을 채우기만 하지 않고 실제로 적용된다 | 서버가 코드를 넣고 `checkout_options.discount: false`로 칸을 숨긴다 |
| V08-3 | 한 checkout에 두 변형을 열고 연간을 고르면 월간 전용 코드가 오류 없이 빠진다 | 연간은 할인 없음 |
| V08-4 | 체험 중 해지 → 접근이 끝나는 시각 | 서버는 LS의 `ends_at`을 따르되 체험 끝을 넘지 않게 자른다 |
| V08-5 | 결제 실패 · 복구(테스트 카드) → `past_due` 동안 AI 됨, 갱신일 | LS의 `renews_at`은 믿지 않고 마지막 유료 기간 끝 + 16일만 쓴다 |
| V08-6 | 해지 · 기간 끝 · 다시 시작(`cancelled: false`) | PATCH 한 번 뒤 webhook 또는 다시 읽기로 `active` |
| V08-7 | 72시간 안 환불(구독 · Lifetime) → webhook이 오는지 | 안 와도 inbox 다시 읽기로 확정한다. 환불 뒤 구독이 자동 취소되지 않아도 서버가 취소한다 |
| V08-8 | 셀프 환불 두 번째 거절 · 72시간 밖 거절 | DB가 계정당 1회, LS 시각 기준 |
| V08-9 | Lifetime 주문 → 자격, Pro 중 Lifetime 겹침 → Pro 취소 | `order_created`의 `meta.custom_data`에 checkout_ref가 온다 |
| V08-10 | 중복 · 역순 · 서명 없는 전달(401) · 모드 다른 전달(400) · 다른 계정 intent 거절 | |
| V08-11 | 인보이스 목록이 최신순인지, 체험 구독에 인보이스가 없는지, `trial_ends_at`이 전환 뒤 null인지 | 최신 1건만 본다 / 체험은 구독만 본다 / 전환 뒤 값은 DB에 남겨 둔 것을 쓴다 |
| V08-12 | 고객 포털에서 월 ↔ 연 바꾸기 → `subscription_updated`의 변형으로 plan이 바뀐다 | `billing_plan_changed` 이벤트 |
| V08-13 | **공유 구매 링크**(LS 상품 페이지의 일반 링크)가 `checkout[custom][checkout_ref]`를 받는가, 그리고 checkout 화면에 `checkout_ref`가 사용자에게 보이는가 | 받으면 구매자가 참조를 바꿔 남의 intent에 묶을 수 있다. 서버는 처음 묶을 때만 intent의 `user_id` · `with_trial` · `with_discount`를 확인해 확실한 조작이면 구독을 취소하고(`billing_duplicate_purchase`), 그 밖은 `billing_review_needed`로 사람이 본다. 보이지 않으면 사용자가 참조를 알아내기 어렵다 |
| V08-14 | 첫 달 할인 코드를 쓴 첫 인보이스에 `discount_total`이 0보다 크게 오는가 | 서버는 이 값으로 "할인이 있었는데 intent에 `with_discount`가 없었다"를 가린다: 처음 묶는 결제면 취소 + 검토, 이미 묶인 체험의 첫 결제면 `billing_review_needed`만. 필드가 없으면 할인 확인은 비어 있다(안전하지 않은 쪽이 아니라 놓치는 쪽) |
| V09-1 | 저장: 실제 OpenRouter 키 1개(사용자 소유)를 `PUT`하면 `GET /api/v1/key`로 확인한 뒤 저장되고 `{ai_key: connected}`만 돌아온다. 관리 키는 `ai_key_management`, 잘못된 키는 `ai_key_invalid` | 확인은 비용 0. `is_management_key`가 응답에 온다 |
| V09-2 | 추출 · 대화 · 임베딩 · Jev가 사용자 키로 간다(OpenRouter 활동 로그와 대조). 관리형 원가 장부(`ai_spend_attempts`)에는 그 사용자 행이 0 | `budgetFetch`가 헤더를 교체하고 예약 · 정산을 건너뛴다 |
| V09-3 | generation의 공급자 이름이 우리 목록(ZDR) 안에 있다. 키 주인 계정의 허용 공급자가 우리 목록과 겹치지 않으면 404 · 503으로 **실패**하고 조건을 약하게 바꿔 다시 보내지 않는다 | 요청마다 `zdr: true` · `data_collection: "deny"` · `only` · `allow_fallbacks: false`가 간다 |
| V09-4 | 키 한도를 $0.01로 줄이면 402가 와서 `ai_key_spend_error_at`이 찍히고 상태는 `connected` 그대로. 한도를 올리면 다음 호출이 성공하고 표시가 거두어진다 | 402 · 403은 폐기하지 않는다 |
| V09-5 | OpenRouter에서 키를 끄면 401 → `revoked`, 그 뒤 호출은 네트워크 0. 새 키를 `PUT`하면 `connected`로 돌아온다 | |
| V09-6 | `DELETE`하면 204, 이후 AI는 "Missing"으로 닫힌다. Lifetime 환불을 확인하면 저장된 키가 지워진다 | BL-20 |
| V09-7 | Vercel 함수 로그 · 오류에 키(또는 `sk-or-`)가 0. 요청 본문이 로그에 남지 않는다 | 6.4. 서버 코드는 키를 로그하지 않지만 호스팅 쪽 기록은 여기서만 볼 수 있다 |
| V09-8 | `ARCH-V09` 때 같이 본다: 임베딩 문서가 `zdr` 인자를 보이지 않는다 · 고정한 Jev `typesafe/jev-1.13`이 공개 ZDR 목록에 있는지 | 이미 있던 확인 항목(BYOK와 별개) |

옛 $9 실측 행렬(성공 · 실패 · 중복 · 역순 · 만료 · 해지 · 환불 · 재구독 · 복구 · 타 계정 거절)도 새 상품으로 한 번씩 다시 돌린다.

## 8. LS 대시보드에서 사용자가 할 일 (테스트 → Live 각각)

1. 상품 "Taskforce Pro": Monthly $12.99/월 · Yearly $119.88/년. 각 가격에 **무료 체험 3일(카드 받기)**. setup fee 끔 · 라이선스 키 끔 · 수량 1 · 세금 별도.
2. 할인: 고정 **$6.00** · 첫 결제만(`once`) · Monthly 변형에만 · 횟수 제한 없음. 코드 값을 `LEMONSQUEEZY_FIRST_MONTH_DISCOUNT_CODE`에.
3. 상품 "Taskforce Lifetime": single payment $229. 수량 단계(몇 개를 $229에)는 사용자가 정한다. 코드는 막지 않는다. 가격을 바꿀 때는 `prices.ts`도 같이.
4. 고객 포털: 해지 · Monthly ↔ Yearly 바꾸기 · 결제 수단 바꾸기 허용.
5. webhook(Live `140533` · 테스트 `140532`)의 사건 목록을 2장의 13개로 맞춘다. 서명 비밀은 그대로.
6. 옛 상품 테스트 `1420342` · Live 초안 `1420403`(및 변형 `2218838` · `2218883` · `2218942` · `2218943`)을 보관 처리한다. 다시 쓰지 않는다. 옛 `UI bento Pro` · `Taskforce Early Bird $39`와 섞지 않는다 — 이 가게의 다른 상품 사건은 서버가 알아보고 무시한다.
7. API 키는 지금 것(2027-04-08 만료)을 쓴다. 만료 전 교체를 일정에 둔다.
8. **옛 `/auth/billing` redirect 허용 항목을 지운다:** Supabase 대시보드 → Authentication → URL Configuration → Redirect URLs에서 옛 결제 복귀 경로(`…/auth/billing` 계열)를 지운다. 새 흐름은 LS 자체 완료 페이지만 쓰고 그 경로를 부르지 않는다. 남겨 두면 쓰이지 않는 허용 목록이 열린 리다이렉트 표면으로 남는다.

## 9. 알려진 한계

- 계정 삭제 뒤 같은 이메일로 다시 가입하면 새 계정이라 체험을 또 받는다(LS가 같은 고객의 두 번째 체험을 막는지는 7장에서 본다).
- 체험 중 $0 구독은 인보이스가 없어, 서버는 구독 객체만으로 판정한다. 체험 도중 서버가 사건을 하나도 못 받으면 접근은 그 사건이 올 때까지 시작되지 않는다(안전한 쪽).
- `GET /api/v1/ai-budget`(지금 Release Mac 옛 창이 읽는다)은 v1 모양을 지킨 채 플랜 상태로 답한다: 기존 베타는 옛 요약 그대로, 체험 · Pro · 해지 · past_due는 `billing_spend_summary_v2`를 **옛 10 단위 눈금**으로 바꿔 내려(숨은 상한 숫자가 새지 않는다, 비율만 보인다), Lifetime은 관리형 원가가 0이라 비어 있는 요약, 플랜이 끝난 계정은 503이 아니라 403 `billing_required`다. 새 Mac은 부르지 않는다.
- 웹 결제 페이지와 로그인 없는 `/billing` 경로 허용을 지웠다(`/billing`은 로그인이 필요한 경로다).
- **잔여 위험(받아들인다):** 남의 결제를 내 계정에 묶는 피싱 — 공격자가 자기 구매 링크로 피해자의 intent(`checkout_ref`)를 달아 결제하게 만들면 피해자 계정에 공격자 아닌 결제자의 구독이 붙는다. 서버는 처음 묶을 때 intent가 그 계정의 것인지 · 체험 · 할인이 맞는지 · 다른 구독에 이미 묶였는지만 확인할 수 있고, 결제자가 계정 주인인지는 알 수 없다. 영향은 계정 주인이 공짜로 구독을 얻는 쪽이라 주인에게 해가 없고, 결제자의 환불 · 분쟁은 LS에서 처리된다. V08-13의 결과로 위험이 커 보이면 다시 정한다. PR 본문에도 같은 문장을 적는다.
- 이 PR이 늘린 `metric_events` type 20개(결제 · 키)는 리텐션 활동에 들어가지 않는다: `src/lib/metrics/compute.ts` `metricActivity`가 등록부(`BILLING_EVENTS`)로 빼고 시험이 고정한다(갱신 webhook이 재방문으로 세지 않는다). 읽는 결제 카드(`/admin/metrics`)는 후속이다.
- 확인 필요: Vercel 함수 로그가 요청 본문을 남기지 않는지(운영에서 한 번, V09-7), LS가 주문 · 구독 사건을 순서대로 보내는지(보장하지 않는다고 보고 `updated_at`으로 순서를 맞춘다).
- BYOK 한계는 10장 끝에 따로 적었다.

## 10. BYOK — Lifetime 사용자의 OpenRouter 키 (PR-B)

**무엇:** Lifetime 사용자가 붙여 넣은 OpenRouter 키를 서버가 암호화해 두고, 그 사용자의 AI 호출(추출 · 대화 · 임베딩 · Jev · 초안)만 그 키로 보낸다. 모델 비용은 사용자의 OpenRouter 계정에 청구되고 Taskforce의 원가 장부 · 운영 전체 상한에는 세지 않는다. 키 보관은 서버 표(Mac 키체인 아님)다 — 동기화 cron · 재시도 · 코디네이터는 Mac이 꺼져 있어도 그 키가 필요하다.

| 무엇 | 어떻게 |
|---|---|
| 보관 | 표 `user_ai_keys`(사용자당 한 행). 앱이 AES-256-GCM으로 봉인한 글자 `k1.<iv>.<tag>.<ct>`만 들어간다. AAD = `openrouter:<user_id>`라서 다른 사용자의 암호문을 이 사용자의 행에 옮겨도 열리지 않는다. 키는 env `USER_AI_KEY_ENCRYPTION_KEY` 하나(`key_version` 열은 회전 때를 위해 둔다) |
| 클라이언트 | 표에 `anon` · `authenticated` 권한이 없다(RLS `owner_all` 정책은 있으나 권한이 0). 읽기도 쓰기도 서버(service role)만. 상태는 `GET /api/v2/billing`의 `ai_key`(connected · missing · revoked)와 `ai_key_spend_error_at`뿐이고 키 · 암호문 · 일부(끝 4자 같은 힌트)는 어디에도 내리지 않는다 |
| 저장 | `PUT`: 로그인 → Lifetime인지 확인 → 모양(접두 `sk-or-`, 길이 20–256, 보이는 글자만, 앞뒤 공백 지움) → **사용자별 시간당 10회 속도 제한(`ai_key`)** → `GET https://openrouter.ai/api/v1/key`(비용 0, 10초)로 확인 → 봉인해 `ai_key_put`. 401은 422 `ai_key_invalid`, 관리 키는 422 `ai_key_management`, 5xx · 시간 초과 · 모양이 다른 답 · **관리 키 표시(`is_management_key` · 옛 `is_provisioning_key`)가 없는 답**은 확인하지 못한 것이라 저장 없이 503, 한도 초과는 429 + `Retry-After`. 확인하지 못한 키는 저장하지 않는다. DB가 권한 행을 공유 잠금으로 쥐고 다시 확인하므로, 확인하는 동안 환불이 들어오면 저장이 거절된다 |
| 사용 | 사용자 호출은 모두 `budgetFetch`(`src/lib/ai/budget.ts`) 한 곳을 지난다. Lifetime이면 호출마다 DB에서 키를 읽어(캐시 없음) `Authorization`을 그 키로 **교체**하고(들어온 관리형 헤더는 버린다) 관리형 예약 · 정산 · 토큰 기록을 건너뛴다. `max_price`와 공급자 정책(ZDR · 고정 목록)은 그대로 붙는다. 키가 없음 · 폐기 · 열리지 않음 · `BYOK_ENABLED` 꺼짐이면 네트워크 호출 0으로 닫는다(v1 코드 `billing_required`, 문구 N13) |
| 제공자 응답 | 401 → 그 암호문을 `revoked`로 표시하고(이벤트 `ai_key_revoked`) 사용자가 새 키를 넣을 때까지 호출하지 않는다. 402 · 403(잔액 · 키 한도 · 가드레일 · 검열) → 응답을 그대로 돌려주고 `last_spend_error_at`만 남긴다. 상태는 `connected` 그대로라 충전하면 바로 된다. 성공하면 표시가 거두어진다. 표시는 그 호출이 쓴 바로 그 암호문에만 적용된다 |
| 지우기 | `DELETE`(이벤트 `ai_key_deleted`) · Lifetime 환불 확인(BL-20) · 계정 삭제(FK cascade). `BYOK_ENABLED`를 끄는 것은 지우지 않는다(호출만 멈춘다). 끈 동안에도 사용자는 `DELETE`로 지울 수 있다 |
| 로그 | 키는 `PUT` 본문으로만 들어오고 응답 · 오류 · 이벤트 · `console`에 없다. OpenRouter 오류 본문(`.detail`, 500자)은 `src/lib/ai/scrub.ts`가 `sk-or-…` 모양을 `sk-or-[가림]`으로 바꾼 뒤에만 담는다 |
| 이벤트 | `ai_key_saved {replaced}` · `ai_key_deleted`(어떤 길로 지워지든 삭제 트리거가 한 번: 사용자의 DELETE `{}`, Lifetime 환불 · 사기 확정 `{by: refund}`, 그 밖의 직접 삭제 `{by: system}`, 계정 삭제는 남기지 않는다) · `ai_key_revoked {by: provider}`. 키 · 라벨 · 암호문은 props에 없다. 리텐션 활동에 들어가지 않는다 |

**ZDR(처리방침 약속)과 BYOK:** 요청마다 보내는 `provider`(`zdr: true` · `data_collection: "deny"` · `only` · `allow_fallbacks: false`)는 사용자 키에도 그대로 간다. 키 주인 계정의 허용 공급자 목록은 천장이라 우리 `only`와 겹치지 않으면 요청이 **실패**한다(조건을 약하게 바꿔 다시 보내지 않는다). **막을 수 없는 것:** OpenRouter가 계정 단위로 주는 선택 기능("Input & Output Logging" · "Use of Inputs/Outputs" 1% 할인)은 요청 인자로 끌 수 없고 `GET /key`로 켜졌는지 알 수도 없다. 그래서 처리방침(PR-D)과 Mac 각주(N10)에 "계정의 로깅 설정은 사용자가 정한다"를 적는다.

**키 회전 / 사고 대응:**
- 한 키만 쓴다(BL-21 A). `USER_AI_KEY_ENCRYPTION_KEY`를 바꾸면 모든 저장 키가 열리지 않는다 → 그 Lifetime 사용자의 AI는 N13("Add your OpenRouter key…")으로 닫히고, 각자 키를 다시 넣으면 된다.
- 암호화 키가 새어 나간 것으로 의심되면: ① env를 새 값으로 바꾸고(`CONNECTOR_TOKEN_KEY`와 다르게) 재배포 ② 옛 암호문을 지운다 — `delete from public.user_ai_keys;`(승인된 운영 질의, 한 명령에 한 문장) ③ 사용자에게 OpenRouter에서 옛 키를 폐기하고 새 키를 넣도록 알린다(암호문만 새면 env 키 없이 열리지 않지만, 둘 다 새면 사용자 키가 노출된 것이다).
- `BYOK_ENABLED=false`는 즉시 되돌리기다: Lifetime 판매 · 키 route가 닫히고 Lifetime 계정의 AI는 닫힌 쪽으로 멈춘다(관리형으로 새지 않는다). 표 · 행은 둔다.

**알려진 한계 (BYOK):**
- BYOK 사용자의 실행 영수증 비용은 "모름"일 수 있다: 비용 확정 sweep(`lib/ai/generation.ts`)은 관리형 키로 generation을 찾는데, 사용자 키로 만든 generation은 그 키로만 보일 수 있다. 관리형 원가 장부에 행이 없어 sweep 대상도 아니다. 영수증의 비용 칸은 비어 있어도 청구에는 영향이 없다(사용자의 OpenRouter 청구서가 기준).
- 한도 오류 표시(`ai_key_spend_error_at`)는 다음 성공 호출이 거둔다: 충전한 직후 AI를 쓰지 않으면 표시가 남아 있다.
- 열리지 않는 봉인 글자(env 키 교체 · 행 이동)는 호출에서 "키 없음"으로 다루고 상태 응답은 행의 `status`(`connected`)를 그대로 내린다. 사용자가 키를 다시 넣으면 풀린다.
- 계약 8장 표는 `BYOK_ENABLED`가 꺼지면 `DELETE`도 404라고 적었으나, 개인정보를 위해 사용자가 언제나 키를 지울 수 있게 `DELETE`는 플래그와 상관없이 연다(코디네이터 결정 2026-10-20).
- 키 형식은 접두 `sk-or-` · 길이만 본다. 엄격한 정규식은 OpenRouter가 정하는 일이라 `GET /key`가 판정한다.

## 공식 참고

- https://docs.lemonsqueezy.com/api/checkouts/create-checkout
- https://docs.lemonsqueezy.com/api/subscriptions/the-subscription-object
- https://docs.lemonsqueezy.com/api/subscription-invoices/issue-refund
- https://docs.lemonsqueezy.com/api/orders/issue-refund
- https://docs.lemonsqueezy.com/help/webhooks/event-types
- https://docs.lemonsqueezy.com/help/webhooks/signing-requests
- https://docs.lemonsqueezy.com/help/payments/refunds-chargebacks
- https://docs.lemonsqueezy.com/guides/developer-guide/testing-going-live
