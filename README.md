# AI 거버넌스 스타터

ChatGPT와 Claude를 **내 규칙으로** 쓰기 위한 시작 키트입니다. 규칙과 작업 기록을 내 GitHub에 한 번 적어 두면, 어느 AI를 열어도 같은 규칙으로 일하고 서로의 작업을 이어받습니다. AI는 확인한 결과만 "완료"라고 보고합니다.

- **설명서:** https://lifeinbeats9-prog.github.io/ai-governance-starter/
- **시작 문장 만들기:** https://lifeinbeats9-prog.github.io/ai-governance-starter/generator.html

## 세 층 중 필요한 데까지만

| 층 | 이런 분께 | 준비물 | 하는 법 |
|---|---|---|---|
| 기본 | 누구나 | ChatGPT 또는 Claude 계정 | 생성 페이지에서 규칙을 고르고, 나온 글을 AI 설정에 붙여 넣기 |
| 표준 | 바이브코딩을 해 본 분 | 기본 + GitHub 계정 | 이 저장소를 템플릿으로 내 저장소 만들기 → `START_HERE_AI.md`를 AI에게 붙여 넣기 |
| 고급 | 터미널이 익숙한 분 | 표준 + 상시 켜 둔 Mac, OpenAI Platform 계정 | `advanced/mac-agent/README.md` |

## 표준층 빠른 시작

1. 위의 초록색 **Use this template → Create a new repository**를 누릅니다.
2. 새 대화를 열고 [`START_HERE_AI.md`](START_HERE_AI.md) 내용을 통째로 붙여 넣습니다.
3. AI가 묻는 대로 답하고, 화면에 나온 결과를 그대로 붙여 넣으며 따라갑니다.
4. 마지막에 새 대화에서 `부팅`이라고 입력해 `ACTIVE`, `1.0`이 나오면 끝입니다.

## 저장소 구조

```
governance/
  CURRENT.json        정본: 규칙 위치, 기능 켜기/끄기, 작업별 읽을 파일(task_routes)
  BOOT_INDEX.json     부팅 때 읽는 짧은 목차 (자동 생성, 직접 고치지 않음)
  rules/core.md       핵심 규칙: 상태 표시, 확인 전 완료 금지, 되돌리기 어려운 행동 전 확인
  rules/output.md     답변 형식
  rules/persona.md    캐릭터 (선택)
  tasks/*.md          작업별 규칙: 코딩, 글쓰기, 조사, 외부 행동
records/              결정·결과 기록과 양식
bootstrap/            AI 설정에 붙일 시작 문장
docs/                 설명서와 시작 문장 생성 페이지 (GitHub Pages)
tools/                BOOT_INDEX 생성기
advanced/mac-agent/   (고급) AI가 Mac에서 터미널을 쓰게 하는 설치 스크립트
```

## 어떻게 작동하나

1. AI 설정에는 "부팅하면 내 저장소의 목차부터 읽어"라는 짧은 글만 들어갑니다.
2. AI는 대화를 시작할 때 `BOOT_INDEX.json` 하나만 읽습니다.
3. 실제 작업이 오면 목차의 `task_routes`에서 그 작업에 맞는 규칙 파일만 꺼내 읽습니다. 규칙이 많아져도 AI가 무거워지지 않습니다.
4. 중요한 결정과 결과는 `records/`에 쌓여서, 다른 AI나 다음 대화가 이어받습니다.

`CURRENT.json`을 고치면 GitHub Action이 `BOOT_INDEX.json`을 자동으로 다시 만듭니다. 로컬에서는 `python tools/build_boot_index.py --write`.

## 솔직한 한계

- AI가 규칙을 100% 지키지는 않습니다. 그래서 확인됨과 미확인을 구분하는 규칙이 핵심입니다.
- 공개 저장소는 누구나 읽을 수 있습니다. 규칙에 개인 정보를 쓰지 마세요.
- AI 서비스의 메뉴 이름과 위치는 바뀔 수 있습니다.
- 고급층은 Mac의 사용자 계정과 권한을 바꿉니다. 터미널 출력을 읽을 수 있는 분께만 권합니다.
