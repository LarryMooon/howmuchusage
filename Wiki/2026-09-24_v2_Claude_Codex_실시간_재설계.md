# 2026-09-24 v2 재설계: Claude + Codex 실시간 사용량 메뉴바

> 이 문서는 v2 설계의 source-of-truth다. 사람이 훑어보기 쉬운 companion view는 `docs/v2-design.html`에 있다.

## 1. 사용자 요구 (원문 요약)

- 예전 v0.1.x 코드는 가져오지 않는다. **UI만 원래 프로젝트를 따라간다.** (두 줄 battery bar, 남은 % 기준, 초록/노랑/빨강, 클릭하면 popover)
- 최종 목표: 맥 상단 메뉴바에 **Claude와 Codex 사용량**을 실시간으로 자동 업데이트해서 보여주는 앱.
- 원하는 품질: 안정적인 연결, 안정적인 업데이트, 신뢰도 있는 표시, 계정 연결 편의성.
- **웹/맥/아이패드/아이폰 어디서 쓰든**, 맥이 켜져 있고 앱이 떠 있으면 사용량이 알아서 업데이트되어야 한다.

## 2. 핵심 결론: "로컬 로그 읽기" → "계정(서버) 기준 조회"

v0.1.x의 근본 한계는 `~/.codex/sessions` 로컬 로그만 읽었다는 점이다. 이 방식은 **그 맥에서 Codex를 쓸 때만** 값이 바뀌므로, 아이폰/웹 사용량은 절대 반영되지 않는다.

사용량 제한(5시간/주간)은 **계정 단위로 서버에서 계산**된다. 그러므로 서버가 알려주는 계정 사용량을 주기적으로 물어보면, 어느 기기에서 쓰든 자동으로 반영된다. v2는 이 원칙으로 전부 다시 설계한다.

MCP/커넥터는 사용량 조회 통로가 아니다. (MCP는 모델이 도구를 쓰는 규격이고, 구독 사용량을 노출하지 않는다.) 대신 2026년 현재 각 도구가 공식적으로 또는 사실상 표준으로 제공하는 **계정 사용량 통로**를 쓴다.

## 3. 데이터 소스 조사 결과 (2026-09-24 기준)

| Provider | Source | 공식성 | 범위 | 비고 |
|---|---|---|---|---|
| Codex | `codex app-server` JSON-RPC `account/rateLimits/read` | **공식 프로토콜** (openai/codex `app-server-protocol` v2) | 계정 전체 (모든 기기) | Codex가 토큰 갱신을 직접 처리. `account/rateLimits/updated` push 알림도 있음. 로그인도 `account/login/start`로 가능 |
| Codex | `~/.codex/sessions/**/*.jsonl` 의 `rate_limits` | 비공식 (로그 파일) | 서버 값이지만 **이 맥에서 Codex를 쓸 때만 갱신** | fallback 전용 |
| Claude | `GET https://api.anthropic.com/api/oauth/usage` + Claude Code OAuth 토큰 (Keychain `Claude Code-credentials`) | **비공식** (Claude Code 내부 `/usage`가 쓰는 endpoint) | 계정 전체 (claude.ai 웹/앱/Claude Code 공유 한도) | 응답: `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `extra_usage`. `utilization` 0–100, `resets_at` ISO-8601. 잦은 호출 시 429 보고 사례 있음 → 보수적 polling |
| Claude | Claude Code statusline stdin JSON의 `rate_limits` | **공식 문서화** (code.claude.com/docs/en/statusline) | 서버 값이지만 **이 맥에서 Claude Code가 돌 때만 갱신** | `five_hour`/`seven_day` 의 `used_percentage`, `resets_at`(epoch 초). bridge script로 파일에 기록 |

확인 근거:

- Codex protocol: `openai/codex` 저장소 `codex-rs/app-server-protocol/schema/typescript/v2/{GetAccountRateLimitsResponse,RateLimitSnapshot,RateLimitWindow,LoginAccountParams,...}.ts`. framing은 줄 단위 JSON이고 `"jsonrpc":"2.0"` 필드를 보내지 않는다 (`src/rpc.rs` 주석).
- Claude statusline: 공식 문서의 `rate_limits` 필드 표와 예시.
- Claude OAuth usage: 공개 문서 없음. 커뮤니티 도구 다수가 같은 endpoint/헤더(`anthropic-beta: oauth-2025-04-20`)를 사용. **공식 API가 아니므로 언제든 바뀔 수 있다**는 전제를 UI와 README에 명시한다.

## 4. 아키텍처

```
┌──────────────── Howmuchusage.app (menu bar only, LSUIElement) ────────────────┐
│  StatusItemView (원래 UI: 2줄 battery bar × provider)   Popover   Settings     │
│                         ▲                                                     │
│                   UsageStore (@MainActor, ObservableObject)                   │
│                         ▲  (provider별 최신 스냅샷 + 상태 + 신뢰도 계산)        │
│             RefreshScheduler (PollPolicy: 적응형 주기, backoff, 트리거)        │
│          ┌──────────────┴───────────────┐                                     │
│   CodexProvider                     ClaudeProvider                            │
│   ├ AppServerSource (primary)       ├ OAuthUsageSource (primary)              │
│   │   codex app-server (stdio)      │   /usr/bin/security → Keychain token    │
│   │   rateLimits/read + push        │   GET /api/oauth/usage                  │
│   └ SessionLogSource (fallback)     └ StatuslineBridgeSource (보조)           │
│       ~/.codex/sessions               ~/Library/Application Support/...json   │
└───────────────────────────────────────────────────────────────────────────────┘
```

SwiftPM target 구성:

- `UsageCore` — Foundation만 사용. 공통 모델, 각 소스 응답 파서, 신뢰도(Freshness) 판정, PollPolicy, 표시 formatter. 단위 테스트 대상.
- `UsageProviders` — 실제 연결 계층. `CodexAppServerClient`(Process + stdio JSON-RPC), `ClaudeCredentialStore`(Keychain/파일), `ClaudeUsageClient`(URLSession), 로컬 소스 reader, statusline bridge installer.
- `Howmuchusage` — AppKit `NSStatusItem` + SwiftUI popover/settings.
- `howmuchusage-probe` — 디버그 CLI. 맥에서 `swift run howmuchusage-probe all` 로 연결 상태를 바로 확인.

## 5. 공통 데이터 모델

- `UsageWindow { kind(session/weekly/weeklyModel(name)/other), usedPercent, resetsAt?, durationMinutes? }`
  - 화면에는 항상 **남은 비율 = 100 - used** 를 쓴다 (v0.1 교훈 유지).
- `UsageSnapshot { provider, windows[], plan?, account?, source, observedAt, extras(credits 등) }`
  - `observedAt` = 그 값이 **서버에서 관측된 시각**. (로컬 소스는 로그 기록 시각)
- 여러 소스 병합 규칙: 모든 소스는 결국 서버가 준 값이므로 **observedAt이 가장 최신인 스냅샷이 이긴다.** 소스 이름은 popover에 표시한다.

## 6. 신뢰도 있는 표시 (Freshness)

| 상태 | 조건 | 메뉴바 표시 |
|---|---|---|
| `live` | 최신 값 나이 ≤ 해당 provider polling 주기 × 2 + 30초 | 정상 색, 라벨 `5h` `1w` |
| `recent` | 나이 ≤ 15분 | 정상 색, 라벨 앞 `~` |
| `stale` | 나이 > 15분 | 회색, 라벨 앞 `~` |
| `resetPassed` | window `resetsAt` 이 지남 | 남은 100%로 **추정 표시** + `~` (다음 조회에서 확정) |
| 연결 안 됨 | 값 없음 | `--` |

- 오류가 나도 마지막 값을 지우지 않는다. 대신 나이가 들수록 `~` → 회색으로 자연스럽게 신뢰도가 떨어지게 보인다.
- popover에는 항상 `● Live · 12s ago · app-server` 처럼 **상태 + 나이 + 소스**를 한 줄로 보여준다.
- 공식 화면 링크: Codex `https://chatgpt.com/codex/settings/usage`, Claude `https://claude.ai/settings/usage`.

## 7. 안정적인 업데이트 (RefreshScheduler + PollPolicy)

| | Codex (app-server) | Claude (OAuth usage) |
|---|---|---|
| 기본 주기 | 60초 | 120초 |
| active (최근 10분 내 값 변화) | 30초 | 60초 |
| idle (30분 이상 값 변화 없음) | 120초 | 300초 |
| 최소 간격 (수동 새로고침 포함) | 10초 | 45초 |
| 오류 backoff | 30초부터 ×2, 최대 15분, ±10% jitter | 동일, 429는 `Retry-After` 우선 (최소 5분) |

즉시 새로고침 트리거 (최소 간격은 지킴):

- 맥이 잠자기에서 깨어남 (`NSWorkspace.didWakeNotification`)
- 네트워크 복구 (`NWPathMonitor`)
- popover 열기
- 로컬 소스 파일 변경 (Codex 세션 로그, Claude statusline bridge 파일) — 이 맥에서 쓰는 중이라는 신호
- Codex `account/rateLimits/updated`, `account/updated` push 알림

App Nap 때문에 timer가 늦어지지 않도록 `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)` 로 앱을 깨워둔다 (시스템 잠자기는 막지 않는다).

## 8. 안정적인 연결

### Codex

- `codex` 실행 파일 탐색: 사용자 지정 경로 → `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.npm-global/bin`, `/Applications/Codex.app` 내부 → 마지막으로 login shell `command -v codex`. (GUI 앱은 터미널 PATH를 상속하지 않기 때문)
- app-server 프로세스는 **계속 띄워두고 재사용**한다. 죽으면 backoff로 재시작한다.
- 요청마다 timeout 20초. (커뮤니티 보고: 4초 timeout은 부하 시 실패)
- 인증 토큰 갱신은 Codex app-server가 직접 처리하므로, 한 번 로그인하면 계속 유지된다.

### Claude

- 토큰은 `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` 로 읽는다.
  - Apple 서명된 `security` 도구를 거치므로, 사용자가 Keychain 팝업에서 "항상 허용"을 한 번 누르면 앱을 업데이트해도 다시 묻지 않는다.
  - fallback: `~/.claude/.credentials.json`.
- **토큰을 직접 refresh 하지 않는다.** refresh token을 앱이 쓰면 Claude Code 쪽 로그인이 깨질 수 있다. 토큰이 만료되면 상태를 `토큰 만료`로 보여주고, 1분마다 Keychain만 다시 확인해서 Claude Code가 갱신하는 즉시 자동 복구한다.
- 401 → Keychain 재읽기 1회 후 실패 시 `재로그인 필요`. 429 → `Retry-After` 존중.

## 9. 계정 연결 편의성 (Onboarding)

- 첫 실행 시 popover에 provider별 카드가 보인다.
- **Codex**: `ChatGPT로 로그인` 버튼 → app-server `account/login/start {type:"chatgpt"}` → 브라우저 열림 → `account/login/completed` 받으면 자동 연결. 이미 Codex CLI/앱에 로그인돼 있으면 **아무것도 안 해도 바로 연결**.
- **Claude**: Claude Code 로그인이 감지되면 `Keychain 접근 허용` 버튼 한 번. 없으면 `터미널에서 로그인` 버튼 → Terminal에서 `claude` 실행 안내(`/login`).
- 선택: `Claude Code statusline 연동` 토글 → `~/.claude/settings.json` 백업 후 bridge 설치. 기존 statusline 명령이 있으면 그대로 이어서 실행한다 (사용자 화면을 깨지 않음).

## 10. 크로스 디바이스 동작 시나리오

| 사용 위치 | 반영 경로 | 예상 반영 지연 |
|---|---|---|
| 아이폰/아이패드 Claude 앱, claude.ai 웹 | Claude OAuth usage polling | 1–5분 |
| 맥 Claude Code | OAuth polling + statusline bridge 파일 변경 즉시 트리거 | 수 초–1분 |
| ChatGPT 앱/웹의 Codex, Codex cloud | app-server polling | 30초–2분 |
| 맥 Codex CLI/앱 | app-server push + 세션 로그 변경 트리거 | 수 초 |

알려진 한계: 맥의 Claude Code를 오래 안 쓰면(토큰 만료) Claude 값 갱신이 멈출 수 있다. → Phase 2에서 `claude.ai 웹 로그인 세션` 소스(WKWebView 로그인, 장기 세션)를 추가해 해결 예정.

## 11. UI (원래 UI 계승)

- 메뉴바: provider마다 원래와 같은 **2줄 블록** (`5h` / `1w`, 얇은 battery bar, 남은 %). 블록 왼쪽에 작은 provider 태그(`CL`, `CX`).
- 표시 모드: `Both`(기본) / `Claude only` / `Codex only`. 연결 안 된 provider는 자동 숨김.
- 색상 기준 유지: 남은 ≤5% 빨강, ≤10% 노랑, 그 외 초록. stale은 회색.
- popover: provider 섹션마다 상태줄(● Live · 나이 · 소스), battery row(원래 디자인), reset 시각, 모델별 주간 한도(Claude Opus/Sonnet 등, 있을 때만), 연결/재연결 버튼. 하단: `Refresh Now`, `Launch at Login`, `Quit`.

## 12. 개인정보 원칙

- 대화 내용, prompt, 응답은 읽지도 저장하지도 않는다. 사용량 숫자와 reset 시각만 다룬다.
- 토큰은 메모리에만 두고 디스크/로그에 쓰지 않는다. 네트워크 요청은 Anthropic/OpenAI 공식 도메인으로만 나간다 (Codex는 app-server가 직접 요청).

## 13. 검증 계획

- 리눅스 클라우드 환경엔 Swift toolchain이 없고 swift.org 다운로드가 차단돼 있다 → **GitHub Actions macOS runner**에서 `swift build` + `swift test` 를 돌린다 (`.github/workflows/ci.yml`).
- 맥에서 사용자가 확인할 항목 (실제 계정 필요):
  1. `swift run howmuchusage-probe codex` → app-server 연결, plan, 5h/1w 값.
  2. `swift run howmuchusage-probe claude` → Keychain 팝업, 5h/7d 값.
  3. 아이폰에서 Claude/ChatGPT Codex 사용 후 1–5분 안에 메뉴바 값이 바뀌는지.
  4. Claude usage endpoint 429 발생 빈도 (발생 시 PollPolicy 기본 주기 상향).

## 14. 로드맵

- Phase 1 (이번 작업): 설계, Core + Providers + 메뉴바 UI + probe CLI + CI.
- Phase 2: claude.ai 웹 세션 소스(장기 로그인), 알림(남은 10%/5% 도달, reset 완료), Developer ID 서명/공증 배포.
- Phase 3: 사용량 히스토리 sparkline, WidgetKit 위젯.

## 15. 작업 로그

- 2026-09-24: 기존 v0.1.2 구조 분석, 데이터 소스 조사, v2 설계 확정. 기존 `Sources/`는 v2 코드로 대체. 기존 Downloads(0.1.x zip)는 legacy로 보존.
- 2026-09-24: v2 구현. `UsageCore` / `UsageProviders` / `Howmuchusage` / `HowmuchusageProbe` 작성, 테스트 42개 작성.
- 2026-09-24: 자체 리뷰에서 찾은 문제와 수정
  - Codex sparse push(`account/rateLimits/updated`)가 첫 full read보다 먼저 도착하면 weekly 창이 빠진 스냅샷이 표시될 수 있었다 → base가 없으면 push를 버리고 다음 정기 조회에 맡기도록 수정, 테스트는 결정적으로 재작성.
  - `ClaudeProvider.read()`의 지역 변수 이름이 메서드와 겹쳐 컴파일 오류가 날 수 있었다 → `self.credentials(...)`로 수정.
- 2026-09-24: GitHub Actions macOS 15 / Swift 6.1.2 CI 첫 실행 통과 (build, 42 tests 0 failures, app bundle, statusline bridge smoke). Node 20 경고로 `actions/checkout@v5`로 올림.
- 2026-09-24: Compound 기록: `docs/solutions/architecture/usage-must-come-from-account-not-local-logs-2026-09-24.md`.
- 다음 할 일: 맥에서 실제 계정으로 13절 검증 체크리스트 수행 → 결과를 이 로그에 기록.
- 2026-09-24: 설치 경로 추가. 클라우드 환경에서는 사용자 맥에 직접 접근 불가 → `.github/workflows/publish-build.yml`(수동 실행 또는 커밋 메시지 `[publish]`)이 macOS에서 universal zip을 만들어 `Downloads/`에 커밋, `Scripts/install.sh` 한 줄 설치. 첫 publish 결과 `Downloads/Howmuchusage-2.0.0-universal-macos.zip` (x86_64 + arm64, SHA-256 확인). Actions artifact 저장소(Azure blob)는 이 환경 네트워크 정책상 다운로드 불가.
- 2026-09-24: **실제 맥 첫 검증** (사용자 스크린샷 + probe 출력)
  - Claude 5h/주간: 공식 화면과 일치 (93% 남음 / 0% 남음, reset 시각 1분 이내 일치). statusline bridge 정상.
  - Claude Fable 주간 한도(공식 97% 사용)가 앱에 없음. 대신 API 코드명 `Iguana Necktie`(= 클라우드 세션 크레딧, $237/$250, 만료 시각 일치), `Nimbus Quill`(정체 미상)이 노출됨.
  - Codex: 사용자 맥에서 `codex` CLI를 못 찾음 → 2일 전 로컬 로그 fallback. 5h reset이 지났다는 이유로 **100%로 추정 표시 (실제 3%)** → 신뢰도 원칙 위반 버그.
- 2026-09-24: 수정
  - reset 추정: 5분 이내 + stale 아님일 때만 100% 추정, 그 외에는 `--` (docs/solutions/logic-errors/passed-reset-is-not-full-quota-2026-09-24.md).
  - Codex 탐색: `~/.codex/bin`, Codex/ChatGPT 앱 번들 내부 검색, 찾은 경로 캐시.
  - Claude 파서: 중첩 객체/배열과 display_name 계열 필드까지 탐색. `.weeklyModel`만 앱에 표시, 정체 불명 코드명은 probe에서만.
  - `howmuchusage-probe --raw`: 서버 원본 응답 출력 (Fable 매핑 확정용).
- 다음 확인 필요: 사용자 맥의 `howmuchusage-probe claude --raw` 결과로 Fable 키 구조 확정, Codex 설치 위치 확인.
