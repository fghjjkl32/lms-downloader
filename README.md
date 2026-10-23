# LMS 다운로더

숭실대 Canvas LMS 강의 영상/자료를 자동 다운로드하고, OpenAI Whisper로 음성을 텍스트로 변환하는 웹 GUI 도구입니다.

## 기능

- 강의 영상 다운로드 (everlec, mp4 등)
- 강의자료 다운로드 (PDF, PPT, 문서 등)
- 공지·과제 첨부파일 다운로드
- 외부 링크 항목을 `.webloc` 링크 파일로 저장
- 학기 선택 (지난 학기, 계절학기, 비정규과정 포함)
- 앱 안에서 Canvas 로그인 (쿠키 자동 저장)
- 자동 음성 인식 (영상 → 텍스트, 선택하면 .srt 자막도 저장)
  - 기본: 내 Mac에서 무료로 처리 (mlx-whisper, Apple Silicon)
  - 선택: OpenAI API 키 또는 OpenAI 호환 서버(VoiceStudio 등)
- PDF/문서 → 마크다운 변환 (markitdown 설치 시)
- 실시간 진행상황 표시

## 사전 준비

### 필수

```bash
brew install ffmpeg jq curl node
```

### 선택

```bash
brew install fzf                    # 터미널 인터랙티브 모드용
pip install 'markitdown[all]'       # PDF→마크다운 변환
```

### 음성 인식 방식

기본값은 **무료 방식**입니다. Apple Silicon Mac에서 mlx-whisper로 처리하므로 API 키가 필요 없습니다.
처음 사용할 때 엔진을 자동으로 설치하고(1~2분, `uv` 또는 Python 3.10 이상 필요) 모델 1.6GB를 내려받습니다.
1시간 강의는 3~4분 정도 걸립니다.

설정의 **처리 방식**에서 OpenAI API 키나 직접 지정한 서버로 바꿀 수 있습니다.

### OpenAI API 키 (OpenAI 방식을 고른 경우)

1. https://platform.openai.com/api-keys 접속
2. "Create new secret key" 클릭
3. 발급된 `sk-...` 키를 웹 GUI 설정에 입력

> Whisper API 요금: 분당 $0.006 (1시간 강의 ≈ 500원)

## 설치 및 실행

### 데스크톱 앱 (권장)

```bash
git clone <repository-url>
cd lms-downloader
npm install
npm run dist
```

`dist/mac-arm64/LMS Downloader.app`을 `/Applications`로 옮긴 뒤 더블클릭해서 실행합니다.
설정과 쿠키는 `~/Library/Application Support/LMS Downloader/`에 저장됩니다.
개발 중에는 `npm run app`으로 빌드 없이 실행할 수 있습니다.

### 웹 버전

```bash
npm install
npm start
```

브라우저에서 http://localhost:8080 접속. 웹 버전에는 로그인 버튼이 없으므로 쿠키 파일을 직접 업로드합니다.

## 사용 방법

### 1단계: Canvas 로그인

데스크톱 앱에서는 **설정** 탭의 **Canvas 로그인** 버튼을 누르고 숭실대 계정으로 로그인합니다.
로그인이 끝나면 창이 저절로 닫히고 쿠키와 토큰이 저장됩니다.

웹 버전을 쓰거나 로그인 창이 동작하지 않을 때는 쿠키 파일을 직접 업로드합니다.

1. Chrome 확장 [Get cookies.txt LOCALLY](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc) 설치
2. https://canvas.ssu.ac.kr 에 로그인
3. 확장 아이콘 클릭 → **Export** 클릭 → 파일 저장
4. 웹 GUI **설정** 탭 → **쿠키 파일 업로드** 버튼 클릭 → 저장한 파일 선택

> 쿠키 업로드 시 Canvas 인증 토큰이 자동으로 추출됩니다.
> 별도로 Canvas 토큰을 입력할 필요가 없습니다.

### 2단계: 강의 선택

1. **강의 선택** 탭 클릭
2. 학기를 고르고 **강의 불러오기** 버튼 클릭
3. 다운로드할 강의를 체크박스로 선택 (전체 선택 가능)

### 3단계: 다운로드

1. **다운로드** 탭 클릭
2. 옵션 설정:
   - 영상 다운로드 (체크/해제)
   - 자료 다운로드 (체크/해제)
   - 공지·과제 첨부 (체크/해제)
   - 음성 인식 (체크/해제, OpenAI 키 필요)
   - 공개 항목만 / 전체
   - 주차 필터 (예: `1,2,3`)
3. **다운로드 시작** 클릭

다운로드된 파일은 설정의 **출력 디렉토리**에 저장됩니다. 앱에서는 **폴더 선택** 버튼으로 Finder에서 고릅니다.

```
output/
  └── 강의명/
      └── 1주차/
          ├── 영상제목.mp4
          ├── 영상제목.txt    ← 음성 인식 결과
          ├── 영상제목.srt    ← 자막 (자막 저장을 켠 경우)
          ├── 자료제목.pdf
          ├── 자료제목.md     ← 마크다운 변환
          └── 링크제목.webloc ← 외부 링크 (더블클릭하면 브라우저로 열림)
      ├── 공지/
      │   └── 공지제목/첨부파일.pdf
      └── 과제/
          └── 과제제목/첨부파일.hwpx
```

## 참고

- 이미 다운로드된 파일은 자동으로 건너뜁니다 (중복 방지)
- 이전 버전에서 자료 파일 대신 뷰어 웹페이지(HTML)가 저장된 경우, 다음 실행 때 자동으로 다시 받습니다
- 24MB 초과 영상은 자동 분할 후 음성 인식 처리
- 쿠키는 일정 시간이 지나면 만료됩니다. 오류 발생 시 쿠키를 다시 추출해서 업로드하세요.
- 개인 설정 파일(`config.json`, `cookies.txt`)은 `.gitignore`에 포함되어 Git에 업로드되지 않습니다.

## 터미널에서 직접 사용 (GUI 없이)

```bash
# 인터랙티브 모드
OPENAI_API_KEY="sk-..." COOKIES_FILE="./cookies.txt" bash lms_download.sh -i

# 특정 강의 다운로드
CANVAS_TOKEN="..." COOKIES_FILE="./cookies.txt" bash lms_download.sh -c 44114

# 영상만 (음성 인식 제외)
bash lms_download.sh -c 44114 --no-transcribe --no-file

# 자료만
bash lms_download.sh -c 44114 --no-video
```

자세한 옵션은 `bash lms_download.sh --help` 참조
