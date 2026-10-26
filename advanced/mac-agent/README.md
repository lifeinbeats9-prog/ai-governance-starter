# 고급: AI가 내 Mac에서 터미널·코딩하기

ChatGPT가 내 Mac에서 터미널 명령, git, 파일 편집, 검색을 직접 하게 만듭니다. 유료 원격 서비스 없이, OpenAI의 **Secure MCP Tunnel**과 오픈소스 **Desktop Commander**(버전 고정)를 씁니다. AI가 건드릴 수 있는 범위는 **macOS 사용자 권한**이 막아 줍니다.

> 터미널 출력을 읽고 판단할 수 있는 분께 권합니다. 이 스크립트는 Mac에 숨김 사용자 2개를 만들고, 폴더 권한(ACL)과 sudoers를 바꾸고, 백그라운드 서비스를 등록합니다. 모두 `uninstall`로 되돌릴 수 있습니다.

## 구조

```
ChatGPT ─ 터널 ─ tunnel-client [aitunnel · 런타임 키 보유]
                   └ sudo → 런처(root 소유) → Desktop Commander [aiagent · 작업 폴더 안에서만 자유]
```

| 사용자 | 할 수 있는 일 | OS가 막는 일 |
|---|---|---|
| `aiagent` | 작업 폴더 안에서 셸, git, 빌드, 파일 편집, 검색, 프로세스 | 내 홈 폴더, 작업 폴더 옆 폴더, 내 프로세스 종료, sudo, 런타임 키 읽기 |
| `aitunnel` | tunnel-client 실행, 키 보유 | 런처 외 다른 명령을 aiagent로 실행 |

## 준비물

- 상시 켜 둔 Mac (macOS, 관리자 계정)
- Homebrew: `brew install node ripgrep openai/tools/tunnel-client`
- Xcode 명령줄 도구 (git, python3): `xcode-select --install`
- OpenAI Platform 계정: 터널 1개와 **Restricted 런타임 키**(Tunnels Read + Use)
- 커스텀 MCP 커넥터를 쓸 수 있는 ChatGPT 요금제
- 작업 폴더: **외장 디스크**(`/Volumes/이름/...`) 또는 **`/Users/Shared/...`**. 홈 폴더 안은 안 됩니다. AI가 홈을 통과할 수 없게 막기 때문입니다.

터널 만들기는 [tunnel-client 안내서](https://github.com/openai/tunnel-client/blob/master/docs/end-user-guide.md)를 따르세요. 터널 ID(`tunnel_...`)만 있으면 됩니다.

## 순서

이 폴더의 파일 3개를 Mac의 한 폴더에 두고 터미널에서:

```bash
cp agent.conf.example agent.conf    # 1. TUNNEL_ID와 WORKSPACE를 채운다
sudo ./setup.sh check               # 2. 읽기 전용 점검. 🔴가 있으면 고치고 다시
sudo ./setup.sh normalize-ownership # 3. (외장 디스크이고 check가 요청할 때만)
sudo ./setup.sh install             # 4. 사용자·권한·Desktop Commander 설치 (아직 안 켜짐)
sudo ./setup.sh key                 # 5. 새 Restricted 키 붙여넣기 (화면에 안 보임)
sudo ./setup.sh test                # 6. 양·음성 검수. PASS_ALL이 목표
sudo ./setup.sh start               # 7. 켜기, 그다음 아래 "전체 디스크 접근"
sudo ./setup.sh keepawake           # 8. (선택) 잠자기 끔, 정전 후 자동 재시작
```

`sudo`가 묻는 비밀번호는 **Mac 로그인 비밀번호**입니다. 입력해도 화면에 안 보이는 게 정상입니다.

### 7단계 뒤: 전체 디스크 접근

macOS 개인정보 보호(TCC) 때문에 백그라운드 서비스는 외장 디스크나 공유 폴더를 바로 열지 못합니다. `test`는 터미널의 허락을 물려받아 통과하지만, 서비스는 따로 허락이 필요합니다.

1. 시스템 설정 → 개인정보 보호 및 보안 → **전체 디스크 접근 권한** → `+`
2. ⌘⇧G → `/usr/local/libexec/ai-agent/tunnel-client/tunnel-client` → 열기 → 켜기
3. `sudo ./setup.sh stop && sudo ./setup.sh start`

이 권한은 macOS 개인정보 보호만 통과시킵니다. 사용자 권한 경계(홈 폴더 거부 등)는 그대로입니다.

### ChatGPT 연결

ChatGPT에서 커스텀 MCP 서버를 추가하고, 연결 방식으로 **Tunnel**을 골라 터널 ID를 넣습니다. 메뉴 이름은 바뀔 수 있습니다. 연결되면 ChatGPT에게 두 가지를 시켜 확인하세요.

- 🟢 작업 폴더의 git 저장소에서 `git status` → 성공해야 함
- 🔴 `ls /Users/내아이디` → **거부돼야** 함

둘 다 맞으면 끝입니다.

## 검수 항목 (`test`)

| 돼야 하는 것 | 막혀야 하는 것 |
|---|---|
| 셸이 aiagent로 실행 | 내 홈 폴더 목록·읽기 |
| git 실행 | 작업 폴더 옆 폴더 전부 |
| 작업 폴더 쓰기·읽기 | 내 프로세스 신호·종료 |
| 작업 폴더에서 셸 | sudo (OS 단에서) |
| 내용 검색 | 작업 폴더 밖 쓰기 |
| 세션 시작·종료 | Desktop Commander 설정 변경, 런타임 키 읽기 |

## 알려진 함정

| 증상 | 원인 | 해결 |
|---|---|---|
| check: `Ignore ownership is ON` | 외장 디스크가 권한을 무시하도록 설정됨 | `normalize-ownership` |
| start: `tunnel-client: Permission denied` | Homebrew 폴더가 주인만 열 수 있음 | `start`가 검증된 사본을 자동으로 만듦 |
| ChatGPT에서 `Operation not permitted` | 서비스에 전체 디스크 접근이 없음 | 7단계 뒤 안내 |
| 재부팅 후 연결 안 됨 | 로그인 전 외장 디스크 미마운트 | `keepawake` |

## 남는 경계

- aiagent는 시스템 전체에서 누구나 읽을 수 있는 파일(`/Applications`, Homebrew 등)과 다른 사용자의 프로세스 목록은 볼 수 있습니다 (macOS 기본 동작).
- 인터넷 연결은 열려 있습니다 (npm, git에 필요). 셸을 준다는 것은 작업 폴더 내용을 밖으로 보낼 수 있다는 뜻이기도 합니다.
- 화면을 보고 앱을 클릭·입력하는 GUI 조작은 포함하지 않습니다.

## 검증 상태

- 🟢 원본 구성(같은 구조, 다른 이름과 경로)은 실제 Mac에서 검수 23/23, ChatGPT 실호출 4/4를 통과했습니다.
- 🟢 이 일반화 버전의 검수 하네스는 Linux 시뮬레이션에서 17/17 통과했습니다.
- ⚪ 이 일반화 버전의 `setup.sh` 자체는 아직 Mac에서 처음부터 실행해 보지 않았습니다. 처음 쓰는 분은 `check`와 `test` 결과를 꼭 확인하세요.
