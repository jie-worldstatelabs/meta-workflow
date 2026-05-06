# stagent

[English](./README.md) | [简体中文](./README.zh-CN.md) | [日本語](./README.ja.md) | **한국어** | [Français](./README.fr.md) | [Deutsch](./README.de.md) | [Español](./README.es.md)

**설정 기반 개발 워크플로우**를 상태 머신으로 실행하는 Claude Code 플러그인입니다. 단일 `workflow.json` 안에 stage, 전이, 입력을 선언하면, 플러그인의 hook과 스크립트가 루프를 구동합니다.

두 가지 모드:
- **Cloud**(기본값) — 상태가 [호스팅된 웹앱](https://stagent.worldstatelabs.com/)에 미러링되어 브라우저에서 라이브로 볼 수 있고, 머신 간 재개가 가능하며, 프로젝트 디렉터리에 자취가 남지 않음.
- **Local** — 상태와 artifact는 `<project>/.stagent/` 아래에 저장되며, 네트워크가 필요 없음.

## Quick Start

### 설치

다음 슬래시 명령을 **Claude Code 세션 안에서** 실행하세요. Cloud 모드는 기본으로 켜져 있어 — 설정이나 키가 필요 없고, 익명 세션에서 `/stagent:start`와 `/stagent:continue`가 동작합니다. 워크플로우를 hub에 publish하거나 인증된 소유권을 주장할 때만 계정(`/stagent:login`)이 필요합니다.

```
/plugin marketplace add jie-worldstatelabs/stagent
/plugin install stagent@stagent
```

이미 설치되어 있나요? 업데이트:

```
/plugin update stagent@stagent
```

필요 항목: [Claude Code](https://claude.ai/claude-code), `jq`, `curl`, `git` (cloud 모드는 `sha256sum` / `shasum` 같은 표준 POSIX 도구도 사용).

### 워크플로우 실행하기

**선택 사항이지만 권장:** session 의 ownership 을 claim 하고 지난 session 들을 더 잘 관리하려면 먼저 로그인하세요.

```
/stagent:login
```

기본 개발 워크플로우 시작 — 당신이 설명한 대로 빌드합니다:

```
/stagent:start --flow=cloud://demo "Build a journaling app with MBTI insights inferred from journal entries"
```

skill 이 라이브 UI URL 을 출력합니다. 로그인하지 않은 상태에서는 이는 **익명, 공개적으로 볼 수 있는** session URL 이며 — 링크를 가진 누구나 상태 머신의 실행을 실시간으로 추적할 수 있고 (stage 타임라인, 렌더링된 artifact, `git diff baseline..HEAD` 가 SSE 로 라이브 업데이트), 소유자는 없습니다.

완전히 오프라인으로 실행하려면 local 모드로 전환:

```
/stagent:start --mode=local "Build a journaling app with MBTI insights inferred from journal entries"
```

### 자신만의 워크플로우 템플릿 만들기

자연어 프롬프트로 자신의 워크플로우 정의 — stagent가 stage를 scaffolding합니다:

```
/stagent:create "plan, implement, critique & score UX"
```

이 명령은 기본적으로 **cloud** 모드로 실행됩니다: planning + writing 스테이지가 끝나면 새 템플릿이 당신의 hub 계정에 publish 됩니다. 아직 로그인하지 않았다면 먼저:

```
/stagent:login
```

완전히 오프라인으로 실행하려면 (템플릿은 로컬 `~/.config/stagent/workflows/<name>/` 에 저장되고 hub 에 push 되지 않습니다) local 모드로 전환:

```
/stagent:create --mode=local "plan, implement, critique & score UX"
```

영감이 필요하신가요? [cookbook](https://stagent.worldstatelabs.com/cookbook)에서 fork하거나 remix할 수 있는 실전 검증된 12개의 워크플로우 템플릿을 살펴보세요.

## 기본 워크플로우

`--flow` 플래그가 없을 때:

- **Cloud 모드**(기본값)는 hub에서 `cloud://demo`를 가져옴 — 이 README와 독립적으로 진화할 수 있는 호스트형 템플릿
- **Local 모드**는 플러그인 번들 워크플로우(`skills/stagent/workflow/`, 오프라인 폴백)를 사용 — 아래 설명되는 사이클의 정전(canonical source)

번들 워크플로우는 **plan → execute → verify → review → QA → deploy** 사이클을 실행합니다:

1. **Planning** *(중단 가능)* — 당신과의 인라인 Q&A: 명확화 질문, 제안된 접근 방법, plan 파일. 당신이 확인하기 전엔 아무것도 빌드되지 않음.
2. **Executing** — subagent(opus)가 plan을 구현: 지정되어 있을 때는 test-first, 최소화·집중된 변경.
3. **Verifying** — 빠른 테스트(unit/integration)를 인라인 실행. FAIL → Execute로 루프; PASS/SKIPPED → Review.
4. **Reviewing** — subagent가 baseline 커밋 대비 적대적 코드 리뷰 실행. PASS → QA; FAIL → Execute로 루프.
5. **QA-ing** — subagent가 실제 사용자 여정 테스트(Playwright, XcodeBuildMCP 등) 실행. 테스트 버그와 앱 버그를 구분 — 확인된 앱 버그만 진행을 막음. PASS → Deploy; FAIL → Execute로 루프.
6. **Deploy** *(중단 가능)* — 인라인 Vercel CLI 흐름: `vercel whoami`, 첫 실행 시 `vercel link`, production env vars 동기화, `vercel --prod`, URL 스모크 체크. 첫 실행 셋업이 다른 터미널에서 `vercel login`이나 당신의 env-var 값이 필요할 수 있어서 중단 가능. 완료 → terminal `complete`.

`execute → verify → review → QA` 루프는 plan 승인 후 **자율적으로** 실행됩니다. Stop hook이 루프가 끝까지 가도록 보장합니다(QA 통과까지; 그 다음 deploy가 마지막의, 중단 가능한 stage로 실행). 루프는 다음 중 하나에서 멈춤: deploy 완료(terminal `complete`), `max_epoch` 도달(기본 `20`, `workflow.json` → `.max_epoch`에서 설정; 폭주 반복을 terminal `escalated` 강제로 끊음), 또는 `/stagent:interrupt`(일시정지)나 `/stagent:cancel`(terminal `cancelled`)로 당신이 개입. 세 terminal — `complete`, `escalated`, `cancelled` — 모두 `workflow.json` → `.terminal_stages`에 선언되어 있음.

## 커스텀 워크플로우

플러그인은 **범용** — 스키마를 따른다면 어떤 stage 형태든 동작합니다. `/stagent:create`(Quick Start 참조)를 실행하면 내부 stagent가 당신을 인터뷰하고, `~/.config/stagent/workflows/<name>/` 아래에 `workflow.json` + 각 stage 명령 파일을 작성하고, 재시도 루프 안에서 검증한 뒤, 번들을 hub에 publish합니다(cloud 모드만). 다음과 같이 재사용:

```
/stagent:start --flow=cloud://<you>/<name> <task>
```

`workflow.json` 스키마는 [ARCHITECTURE.md](./ARCHITECTURE.md)를 참조.

워크플로우로 만들 만한 아이디어가 필요하다면? [cookbook](https://stagent.worldstatelabs.com/cookbook) 참조 — Claude Code의 흔한 실패 모드(goal pursuit, research-first, end-to-end v1, scope lock-down, invariant guardrails, root-cause forced, real bug hunt, strict TDD, real-journey suite, visual QA gate, perf gate, compliance gate)에 대한 즉시 실행 가능한 12개 워크플로우, 각각 `/stagent:start --flow=cloud://...`로 실행할 수 있습니다.

## 명령

| 명령 | 용도 |
|---|---|
| `/stagent:start [--mode=cloud\|local] [--flow=<ref>] <task>` | 새 run 시작 |
| `/stagent:interrupt` | 상태를 지우지 않고 활성 run 일시정지 (stage 중간에서도 호출 가능; `/stagent:continue`로 재개) |
| `/stagent:continue [--session <id>]` | 중단된 run 재개 (`--session`은 머신 간 cloud 인계용) |
| `/stagent:cancel [--hard]` | run 취소. 기본은 아카이브; `--hard`는 완전 삭제. Local 모드 파일도 그에 맞춰 아카이브/삭제; cloud 모드에서는 local shadow가 어느 쪽이든 지워지고 차이는 서버 측에만(archived vs hard-deleted) 있음 |
| `/stagent:create [--mode=cloud\|local] [--flow=<ref>] <description>` | 새 워크플로우 만들기 또는 기존 워크플로우 편집 |
| `/stagent:publish <dir> [--name <n>] [--description <d>] [--dry-run]` | 로컬 워크플로우를 hub에 publish |
| `/stagent:login` / `:logout` / `:whoami` | hub 정체성 관리 |

**`--flow=<ref>`**가 받는 것:
- *(생략)* — cloud 모드는 hub에서 `cloud://demo`를 가져옴; local 모드는 플러그인 번들 워크플로우 사용
- `cloud://author/name` — hub에서 가져옴 (cloud 모드)
- `/abs/path` 또는 `./rel/path` — 로컬 워크플로우 디렉터리
- `<bare-name>` — 먼저 플러그인 번들 워크플로우와 매칭하고, 없으면 hub의 `cloud://<bare-name>`으로 해석

**환경 변수:**

| 변수 | 기본값 | 효과 |
|---|---|---|
| `STAGENT_DEFAULT_MODE` | `cloud` | `local`로 설정하면 셸의 모든 run의 기본을 뒤집음 |

## Local vs Cloud

| 관심사 | Local | Cloud |
|---|---|---|
| 권위 있는 상태 | `<project>/.stagent/<session>/state.md` | Postgres `sessions` 행; local shadow가 미러링 |
| 파일이 디스크에 있는 위치 | 프로젝트 worktree | `~/.cache/stagent/sessions/<session>/` — terminal에서 지워짐 |
| 라이브 뷰어 | 없음 — 파일을 읽음 | `https://stagent.worldstatelabs.com/s/<session_id>` |
| 머신 간 continue | 미지원 | `/stagent:continue --session <id>`, project-fingerprint 검증 포함 |
| `.gitignore` 항목 필요 여부 | `echo '/.stagent/' >> .gitignore` | 없음 |

### 머신 간 / clone 간 인계 주의사항

`/stagent:continue --session <id>`는 워크플로우의 **상태**(`state.md`, stage 보고서, 그리고 `baseline` run-file — 워크플로우 시작 시 캡처된 git SHA)를 새 머신에 미러링합니다. 프로젝트의 소스 코드는 **복사하지 않습니다**. 코드는 당신의 git 저장소에 있고, 플러그인 안에 있지 않습니다.

`continue-workflow.sh`는 다음을 검증:

1. 새 workdir가 같은 저장소인지 (root-commit fingerprint).
2. 새 workdir의 HEAD가 워크플로우가 마지막으로 본 HEAD(`state.md`의 `last_seen_head`, 모든 stage 전이와 `/interrupt`마다 갱신)에 비해 뒤처지거나 / 분기되어 있지 않은지. 뒤처지거나 / 분기된 HEAD는 `--force-project-mismatch`를 전달하지 않는 한 **하드 블록** — 그렇지 않으면 재개된 stage가 오래된 코드에 대해 실행되어 끝난 작업을 다시 하거나 모순되게 됨.
3. 새 workdir에 커밋되지 않은 변경이 있으면 소프트 경고 — 다음 stage의 출력과 충돌할 수 있음.

원래 세션이 중단 전에 subagent의 작업을 커밋했다면, 새 머신에서 `git fetch && git checkout <last_seen_head>`(또는 그 브랜치를 머지)하면 `/continue` 전에 동기화가 됩니다.

## 핵심 설계 결정

- **설정 기반** — stage, 전이, interruptible 플래그, subagent 타입/모델, 입력 의존성 모두 `workflow.json`에 있음. stage 추가나 전이 변경은 설정 편집이지 코드 변경이 아님.
- **하나의 범용 subagent** — 모든 subagent stage는 단일 `workflow-subagent` 아래에서 실행; stage별 프로토콜은 `<workflow-dir>/<stage>.md`에 있고 subagent가 런타임에 읽음. stage별 `subagent_type` 필드는 없음.
- **필수 입력이 전이를 막음** — `update-status.sh`는 어떤 `required` 입력 artifact가 누락된 stage로의 이동을 거부. 상태 머신 레벨의 강제.
- **Epoch가 새겨진 artifact** — 각 stage의 artifact는 생성 당시의 epoch를 포함. stop hook은 `state.md`의 epoch와 일치하는 artifact만 신뢰 — 이전 반복의 stale artifact는 무시.
- **자급자족** — skill은 에이전트가 외부 skill을 호출하지 않도록 지시하여 흐름 하이재킹을 방지.
- **정상 종료는 자동 interrupt** — Claude Code 세션이 깔끔하게 종료될 때(예: `/exit`, 창 닫기), stagent의 `SessionEnd` hook이 활성 워크플로우를 `interrupted`로 뒤집어 다른 Claude 세션이 `/stagent:continue`로 인계할 수 있게 함. 크래시 / `kill -9`에서는 트리거되지 않음; cloud 모드에서는 서버 측 stale 감지가 백스톱.
- **한 세션 = 한 run** — 각 Claude 세션의 run은 자체의 session-keyed 하위 디렉터리에 살음. 같은 worktree의 여러 Claude 세션이 서로 간섭하지 않고 독립적인 워크플로우를 실행할 수 있음.

## 아키텍처 & 내부

[ARCHITECTURE.md](./ARCHITECTURE.md) 참조:
- 플러그인 디렉터리 레이아웃
- 런타임 파일 레이아웃 (local + cloud)
- `workflow.json` 스키마 레퍼런스
- 상태 머신 프로토콜 (epoch, result, transitions)
- Stop-hook 동작
- 엔드투엔드 사이클 워크스루

## License

MIT
