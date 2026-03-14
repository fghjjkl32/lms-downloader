# LMS 다운로더

숭실대 Canvas LMS 강의 영상/자료를 자동 다운로드하고, OpenAI Whisper로 음성을 텍스트로 변환하는 웹 GUI 도구입니다.

## 기능

- 강의 영상 다운로드 (everlec, mp4 등)
- 강의자료 다운로드 (PDF, 문서 등)
- Whisper 자동 음성 인식 (영상 → 텍스트)
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

### OpenAI API 키 (음성 인식 사용 시)

1. https://platform.openai.com/api-keys 접속
2. "Create new secret key" 클릭
3. 발급된 `sk-...` 키를 웹 GUI 설정에 입력

> Whisper API 요금: 분당 $0.006 (1시간 강의 ≈ 500원)
> 음성 인식이 필요 없으면 설정하지 않아도 됩니다.

## 설치 및 실행

```bash
git clone <repository-url>
cd lms-downloader
npm install
npm start
```

브라우저에서 http://localhost:8080 접속

## 사용 방법

### 1단계: 쿠키 파일 업로드

Canvas 영상/자료 다운로드에는 브라우저 쿠키가 필요합니다.

1. Chrome 확장 [Get cookies.txt LOCALLY](https://chromewebstore.google.com/detail/get-cookiestxt-locally/cclelndahbckbenkjhflpdbgdldlbecc) 설치
2. https://canvas.ssu.ac.kr 에 로그인
3. 확장 아이콘 클릭 → **Export** 클릭 → 파일 저장
4. 웹 GUI **설정** 탭 → **쿠키 파일 업로드** 버튼 클릭 → 저장한 파일 선택

> 쿠키 업로드 시 Canvas 인증 토큰이 자동으로 추출됩니다.
> 별도로 Canvas 토큰을 입력할 필요가 없습니다.

### 2단계: 강의 선택

1. **강의 선택** 탭 클릭
2. **강의 불러오기** 버튼 클릭
3. 다운로드할 강의를 체크박스로 선택 (전체 선택 가능)

### 3단계: 다운로드

1. **다운로드** 탭 클릭
2. 옵션 설정:
   - 영상 다운로드 (체크/해제)
   - 자료 다운로드 (체크/해제)
   - 음성 인식 (체크/해제, OpenAI 키 필요)
   - 공개 항목만 / 전체
   - 주차 필터 (예: `1,2,3`)
3. **다운로드 시작** 클릭

다운로드된 파일은 `output/` 폴더에 저장됩니다:

```
output/
  └── 강의명/
      └── 1주차/
          ├── 영상제목.mp4
          ├── 영상제목.txt    ← 음성 인식 결과
          ├── 자료제목.pdf
          └── 자료제목.md     ← 마크다운 변환
```

## 참고

- 이미 다운로드된 파일은 자동으로 건너뜁니다 (중복 방지)
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
