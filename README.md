# LMS 다운로더

숭실대 Canvas LMS의 강의 영상, 강의 자료, 공지·과제 첨부파일을 한 번에 내려받는 Mac 앱입니다.
영상의 음성을 텍스트와 자막(.srt)으로 바꿀 수 있고, 기본값은 내 Mac에서 무료로 처리하는 방식입니다.

버전별 수정 내역은 [CHANGELOG.md](CHANGELOG.md)에 있습니다.

## 기능

- 강의 영상 다운로드 (everlec, mp4 등). 받다가 끊긴 영상은 다음 실행에서 이어받기
- 강의 자료를 원본 파일로 다운로드 (PDF, PPT, HWP 등)
- 공지·과제 첨부파일 다운로드, 본문의 외부 링크(Google Drive, Notion 등)는 `.webloc` 바로가기로 저장
- 외부 링크 강의 항목을 `.webloc`로 저장
- 학기 선택 (지난 학기, 계절학기, 비정규과정 포함), 강의별 주차 선택
- 앱 안에서 Canvas 로그인 (쿠키와 토큰 자동 저장)
- 음성 인식 (영상 → 텍스트, 선택하면 .srt 자막도 저장)
  - 기본: 내 Mac에서 무료로 처리 (mlx-whisper, Apple Silicon)
  - 선택: OpenAI API 키, 또는 OpenAI 호환 서버(VoiceStudio 등)
  - 영상을 저장하지 않고 텍스트만 남기기
- 영상 압축 (목표 크기 이하)
- 필요한 도구(jq, ffmpeg, ffprobe, uv)를 앱 안에서 설치
- 옵션에 따라 저장될 파일과 폴더 구조 미리보기
- 실패한 항목을 원인과 함께 표시하고 Mac 알림으로 알림, 실행 로그 저장

## 설치 (일반 사용자)

**Apple Silicon Mac(M1 이상)** 에서만 동작합니다.

1. [Releases](https://github.com/fghjjkl32/lms-downloader/releases/latest)에서 `LMS.Downloader-<버전>-arm64.dmg`를 받습니다.
2. DMG를 열고 `LMS Downloader`를 **응용 프로그램** 폴더로 끌어다 놓습니다.
3. 처음 열 때 "확인되지 않은 개발자" 경고가 나오면 **시스템 설정 → 개인정보 보호 및 보안**에서 **그래도 열기**를 누릅니다.
   버튼이 보이지 않으면 터미널에서 아래 명령을 실행한 뒤 엽니다.
   ```bash
   xattr -dr com.apple.quarantine "/Applications/LMS Downloader.app"
   ```
4. 처음 실행하면 필요한 도구를 설치할지 묻습니다. **설치**를 누르면 공식 배포 파일(약 53MB)을 체크섬으로 확인한 뒤 앱 데이터 폴더에 설치합니다. Homebrew나 관리자 암호는 필요 없습니다.

자세한 설치 및 사용 방법은 각 Release 페이지 본문(`INSTALL.md`)에 있습니다.

## 사용 방법

앱 위쪽의 **설정**, **강의 선택**, **다운로드** 탭을 차례대로 진행합니다.

### 1. 설정

- **필수 도구**: 도구마다 설치 상태가 나오고, 없는 도구는 **없는 도구 설치**로 설치합니다.
- **Canvas 로그인**: 숭실대 계정으로 로그인하면 앱이 강의콘텐츠 페이지로 자동 이동해 토큰을 받고 창을 닫습니다.
- **출력 디렉토리**: **폴더 선택** 버튼으로 저장할 폴더를 고릅니다.
- **음성 인식 → 처리 방식**
  - **무료: 내 Mac에서 처리** (기본값): 처음 한 번 엔진 설치(1~2분)와 모델 다운로드(약 1.6GB)가 필요합니다. 1시간 강의는 3~4분 정도 걸립니다.
  - **OpenAI API 키 사용**: 분당 $0.006 (1시간 강의 약 500원). [API 키 발급](https://platform.openai.com/api-keys)
  - **직접 지정한 서버**: OpenAI 호환 `/v1/audio/transcriptions` 서버 주소를 입력합니다.

로그인을 쓰지 않을 때는 Chrome 확장 [Get cookies.txt LOCALLY](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc)로 내보낸 쿠키 파일을 **쿠키 파일 업로드**로 올려도 됩니다.

### 2. 강의 선택

학기를 고르고 내려받을 강의를 체크합니다.

### 3. 다운로드

옵션을 체크하면 **저장될 파일 미리보기**에 결과가 바로 나옵니다.

| 옵션 | 저장되는 파일 |
|---|---|
| 영상 다운로드 | `강의제목.mp4` |
| 자료 다운로드 | 강의 자료 원본, 외부 링크 `.webloc` |
| 공지·과제 첨부 | `공지/공지제목/`, `과제/과제제목/` 아래 첨부파일과 링크 |
| 음성 인식 | `강의제목.txt` (영상 다운로드를 끄면 영상은 지우고 텍스트만 남김) |
| 자막(srt) 저장 | `강의제목.srt` (음성 인식을 켰을 때만) |
| 영상 압축 | 영상을 목표 크기 이하로 압축 (영상 다운로드를 켰을 때만) |
| 공개 항목만 | 아직 공개되지 않은 항목은 건너뜀 |

강의마다 주차를 입력하면(예: `1,2,3`) 그 주차만 받습니다. 비워 두면 전체를 받습니다.

```
출력 폴더/
  └── 강의명/
      ├── 1주차/
      │   ├── 영상제목.mp4
      │   ├── 영상제목.txt     ← 음성 인식 결과
      │   ├── 영상제목.srt     ← 자막 (자막 저장을 켠 경우)
      │   ├── 자료제목.pdf
      │   └── 링크제목.webloc  ← 외부 링크 (더블클릭하면 브라우저로 열림)
      ├── 공지/
      │   └── 공지제목/첨부파일.pdf, 외부링크.webloc
      └── 과제/
          └── 과제제목/첨부파일.hwpx
```

이미 받은 파일과 이미 만든 텍스트·자막은 다시 받거나 만들지 않습니다.

## 실패했을 때

- 실패한 항목은 진행 화면의 **문제가 생긴 항목** 카드에 원인과 해결 방법이 함께 나옵니다. Mac 알림으로도 알려 줍니다.
  - 예: 로그인 만료, 인터넷 연결 없음, 시간 초과, 파일 삭제(404), 저장 폴더에 쓸 수 없음, 저장 공간 부족, 음성 인식 메모리 부족, OpenAI 키 오류
- 받을 수 없는 첨부는 이유를 보여 줍니다 (다른 강의의 파일, 비공개, 삭제).
- 다시 다운로드하면 받지 못한 항목만 다시 받습니다. 끊긴 영상은 이어받습니다.
- 실행 로그는 `~/Library/Application Support/LMS Downloader/logs/`에 실행마다 하나씩 저장됩니다 (최근 30개). **전체 로그 폴더 열기** 버튼으로 열 수 있습니다.

### 자주 생기는 문제

- **"포트 8080을 사용할 수 없습니다"**: 이미 실행 중인 LMS 다운로더(`npm start` 포함)를 종료한 뒤 다시 엽니다.
- **강의 목록이 나오지 않음**: 로그인이 만료되었을 수 있습니다. **Canvas 로그인**을 다시 누릅니다. 토큰은 로그인 후 약 2시간 동안 유효합니다.
- **로그인 창이 닫히지 않음**: 아무 강의의 **강의콘텐츠** 메뉴를 열어 봅니다.

## 개발

### 소스에서 실행

```bash
brew install node jq ffmpeg uv
git clone https://github.com/fghjjkl32/lms-downloader.git
cd lms-downloader
npm install
npm run app        # Electron 앱으로 실행
npm start          # 웹 버전 (http://localhost:8080, 로그인 버튼 없음)
```

### 빌드

```bash
npm run dist       # dist/mac-arm64/LMS Downloader.app
npm run dist:dmg   # dist/LMS Downloader-<버전>-arm64.dmg
```

설정, 쿠키, 설치한 도구, 로그는 `~/Library/Application Support/LMS Downloader/`에 저장됩니다.
개인 설정 파일(`config.json`, `cookies.txt`)은 `.gitignore`에 포함되어 있습니다.

### 구조

| 파일 | 역할 |
|---|---|
| `electron/main.js` | 앱 창, Canvas 로그인 창, 폴더 선택, 도구 설치 안내 |
| `electron/deps.js` | jq, ffmpeg, ffprobe, uv를 공식 릴리스에서 받아 체크섬 확인 후 설치 |
| `server.js` | 127.0.0.1:8080 Express 서버. 설정 저장, 강의 목록, 다운로드 실행과 SSE 진행 상황, 실행 로그 |
| `lms_download.sh` | 실제 다운로드와 음성 인식. 실패마다 `[FAIL] 종류: 항목 :: 원인` 줄을 출력 |
| `public/` | 화면 (설정, 강의 선택, 다운로드 탭) |

### 터미널에서 직접 사용

```bash
# 인터랙티브 모드
COOKIES_FILE="./cookies.txt" bash lms_download.sh -i

# 특정 강의 다운로드
CANVAS_TOKEN="..." COOKIES_FILE="./cookies.txt" bash lms_download.sh -c 44114

# 영상만 (음성 인식 제외)
bash lms_download.sh -c 44114 --no-transcribe --no-file

# 자료만
bash lms_download.sh -c 44114 --no-video

# 음성 인식 결과만 (영상은 저장하지 않음)
bash lms_download.sh -c 44114 --no-keep-video --no-file --no-attach

# 자막까지 저장, OpenAI 방식
TRANSCRIBE_ENGINE=openai OPENAI_API_KEY="sk-..." bash lms_download.sh -c 44114 --srt
```

자세한 옵션은 `bash lms_download.sh --help`를 참고하세요.
선택 도구: `brew install fzf` (인터랙티브 모드), `pip install 'markitdown[all]'` (자료를 마크다운으로도 변환).
