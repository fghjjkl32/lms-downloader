#!/bin/bash
# ============================================================
# Canvas LMS 강의 다운로드 + Whisper 자동 transcribe
#
# 사전 요구사항:
#   brew install ffmpeg jq fzf (fzf는 선택, 없으면 숫자 입력 방식)
#
# 환경변수:
#   OPENAI_API_KEY   - Whisper API 키
#   CANVAS_TOKEN     - Canvas API 토큰 (설정 > 액세스 토큰)
#   COOKIES_FILE     - commons.ssu.ac.kr 브라우저 쿠키 파일 경로
# ============================================================

set -uo pipefail

# while 파이프 안(하위 셸)에서 난 실패도 종료 코드에 반영하기 위해 파일에 기록한다
FAIL_LOG=$(mktemp)
trap 'rm -f "$FAIL_LOG"' EXIT
# 앱이 [FAIL] 줄을 모아 실패 목록과 알림을 보여 준다. $(...) 안에서도 보이도록 stderr로 쓴다
mark_failed() {
  echo "$1" >> "$FAIL_LOG"
  echo "  [FAIL] $1 :: ${2:-원인을 알 수 없음}" >&2
}

# curl 종료 코드와 HTTP 상태를 사용자가 이해할 수 있는 원인으로 바꾼다
curl_reason() {
  local rc="$1" http="${2:-000}" dir="${3:-}"
  # curl은 파일을 못 쓸 때도 연결 오류 코드를 낼 수 있어 저장 폴더를 먼저 확인한다
  if [[ -n "$dir" && "$rc" != 0 ]]; then
    if [[ ! -d "$dir" || ! -w "$dir" ]]; then
      echo "저장 폴더에 쓸 수 없음: 외장 드라이브가 분리되었거나 폴더 권한이 없습니다 ($dir)"; return
    fi
    local free_kb
    free_kb=$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ -n "$free_kb" && "$free_kb" -lt 512000 ]]; then
      echo "저장 공간 부족: 남은 공간이 $(( free_kb / 1024 ))MB뿐입니다. 공간을 비우고 다시 시도해 주세요"; return
    fi
  fi
  case "$http" in
    401|403) echo "권한 없음 (HTTP $http): 로그인이 만료되었을 수 있습니다. 설정 탭에서 Canvas 로그인을 다시 해 주세요"; return ;;
    404) echo "파일을 찾을 수 없음 (HTTP 404): 삭제되었거나 비공개로 바뀌었을 수 있습니다"; return ;;
    416) echo "이어받기 실패 (HTTP 416): 다시 실행하면 처음부터 받습니다"; return ;;
    429) echo "요청이 너무 많음 (HTTP 429): 잠시 후 다시 시도해 주세요"; return ;;
    5??) echo "학교 서버 오류 (HTTP $http): 잠시 후 다시 시도해 주세요"; return ;;
  esac
  case "$rc" in
    6) echo "서버 주소를 찾을 수 없음: 인터넷 연결을 확인해 주세요" ;;
    7) echo "서버에 연결할 수 없음: 인터넷 연결을 확인해 주세요" ;;
    18|56|92) echo "다운로드 중 연결이 끊김: 다시 실행하면 이어서 받습니다" ;;
    23) echo "파일을 쓸 수 없음: 저장 공간이 부족하거나 외장 드라이브가 분리되었을 수 있습니다" ;;
    28) echo "응답 시간 초과: 네트워크가 느리거나 끊겼습니다" ;;
    35|60) echo "보안 연결(SSL) 오류: 네트워크(학교 와이파이 로그인 등)를 확인해 주세요" ;;
    *) echo "다운로드 오류 (curl 코드 $rc, HTTP $http)" ;;
  esac
}

# 실패한 명령의 마지막 오류 줄을 원인으로 쓴다
last_error_line() {
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1 | cut -c1-200
}

# ── 기본값 ──────────────────────────────────────────────────
CANVAS_BASE="https://canvas.ssu.ac.kr/learningx"
COURSE_IDS=()
OUTPUT_DIR="./lms_output"
JSON_FILE=""
WEEK_FILTER=""
DO_VIDEO=true
# false면 영상은 음성 인식에만 쓰고 저장하지 않는다
KEEP_VIDEO=true
DO_FILE=true
DO_ATTACH=true
SAVE_SRT=false
# 음성 인식 방식: local(내 Mac에서 무료, mlx-whisper) | openai(API 키, 유료) | server(OpenAI 호환 서버)
TRANSCRIBE_ENGINE="${TRANSCRIBE_ENGINE:-local}"
OPENAI_WHISPER_URL="https://api.openai.com/v1/audio/transcriptions"
WHISPER_URL="${WHISPER_URL:-}"
WHISPER_MODEL="${WHISPER_MODEL:-whisper-1}"
WHISPER_VENV="${WHISPER_VENV:-$HOME/.cache/lms-downloader/whisper-venv}"
LOCAL_WHISPER_MODEL="${LOCAL_WHISPER_MODEL:-mlx-community/whisper-large-v3-turbo}"
DO_TRANSCRIBE=true
DO_COMPRESS=false
COMPRESS_MAX_MB=200
OPENED_ONLY=true
INTERACTIVE_MODE=false
TOKEN_FILE="${HOME}/.canvas_token"

# ── 도움말 ──────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [옵션]

옵션:
  -i, --interactive  인터랙티브 모드 (학기/강의 선택)
  -j <file>        JSON 파일 직접 지정 (없으면 Canvas API로 fetch)
  -c <id>[,<id>]   강의 ID (여러 개: -c 44114,44115 또는 -c 44114 -c 44115)
  -o <dir>         출력 디렉토리 (기본: ./lms_output)
  -w <n>           특정 주차만 처리 (예: -w 1 또는 -w 1,2,3)
  --no-video       영상 다운로드/transcribe 건너뜀
  --no-keep-video  영상은 저장하지 않고 transcribe만 (임시로 받은 뒤 삭제)
  --no-file        자료 파일 다운로드 건너뜀
  --no-attach      공지·과제 첨부파일 다운로드 건너뜀
  --srt            음성 인식 결과를 .srt 자막으로도 저장
  --no-transcribe  transcribe 건너뜀 (영상만 다운로드)
  --opened-only    opened:true 항목만 처리 (기본값)
  --all            미공개 포함 전체 시도
  -h, --help       이 도움말 출력

환경변수:
  TRANSCRIBE_ENGINE  음성 인식 방식: local(기본, 무료) | openai | server
  OPENAI_API_KEY     Whisper API 키 (openai 방식에서 필요)
  WHISPER_URL        OpenAI 호환 음성 인식 주소 (server 방식에서 필요)
  WHISPER_MODEL      openai·server 방식의 모델 이름 (기본: whisper-1)
  CANVAS_TOKEN     Canvas API 토큰 (설정 > 액세스 토큰)
  COOKIES_FILE     commons.ssu.ac.kr 쿠키 파일 (Netscape 형식)

예시:
  # 인터랙티브 모드 (학기/강의 선택)
  $(basename "$0") -i

  # 단일 강의
  CANVAS_TOKEN=... COOKIES_FILE=cookies.txt \\
    $(basename "$0") -c 44114

  # 여러 강의 한번에
  $(basename "$0") -c 44114,44115,44116

  # JSON 파일로
  $(basename "$0") -j modules.json

  # 1~2주차만, 자료만
  $(basename "$0") -c 44114 -w 1,2 --no-video

  # 영상만 (transcribe 제외)
  $(basename "$0") -c 44114 --no-transcribe --no-file

사용 가능한 -w 값 예시:
  -w 1          1주차만
  -w 1,2,3      1·2·3주차
  -w 9,10,11    9~11주차 (후반부)
EOF
  exit "${1:-0}"
}

# ── 인자 파싱 ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interactive) INTERACTIVE_MODE=true; shift ;;
    -j) JSON_FILE="$2"; shift 2 ;;
    -c)
      IFS=',' read -ra _ids <<< "$2"
      COURSE_IDS+=("${_ids[@]}")
      shift 2 ;;
    -o) OUTPUT_DIR="$2"; shift 2 ;;
    -w) WEEK_FILTER="$2"; shift 2 ;;
    --no-video) DO_VIDEO=false; shift ;;
    --no-keep-video) KEEP_VIDEO=false; shift ;;
    --no-file) DO_FILE=false; shift ;;
    --no-attach) DO_ATTACH=false; shift ;;
    --srt) SAVE_SRT=true; shift ;;
    --no-transcribe) DO_TRANSCRIBE=false; shift ;;
    --compress) DO_COMPRESS=true; shift ;;
    --compress-mb) DO_COMPRESS=true; COMPRESS_MAX_MB="$2"; shift 2 ;;
    --opened-only) OPENED_ONLY=true; shift ;;
    --all) OPENED_ONLY=false; shift ;;
    -h|--help) usage 0 ;;
    *)
      echo "Error: 알 수 없는 옵션: $1"
      echo ""
      usage 1
      ;;
  esac
done

# ── 환경변수 / 인자 유효성 검사 ─────────────────────────────
if ! $INTERACTIVE_MODE; then
  if [[ -z "$JSON_FILE" && ${#COURSE_IDS[@]} -eq 0 && -z "${CANVAS_TOKEN:-}" ]]; then
    echo "Error: -c <course_id> 또는 -j <file> 또는 -i (인터랙티브) 이 필요합니다."
    echo ""
    usage 1
  fi

  if [[ -z "$JSON_FILE" && ${#COURSE_IDS[@]} -eq 0 ]]; then
    echo "Error: -c <course_id> 를 지정해주세요."
    echo ""
    usage 1
  fi
fi

# CANVAS_TOKEN은 run_interactive에서 load_or_prompt_token으로 처리

if [[ -n "$JSON_FILE" && ! -f "$JSON_FILE" ]]; then
  echo "Error: JSON 파일을 찾을 수 없습니다: $JSON_FILE"
  exit 1
fi

if $DO_TRANSCRIBE; then
  case "$TRANSCRIBE_ENGINE" in
    local) ;;
    openai)
      if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        echo "Error: OPENAI_API_KEY not set (무료 방식은 TRANSCRIBE_ENGINE=local, 끄려면 --no-transcribe)"
        exit 1
      fi
      WHISPER_URL="$OPENAI_WHISPER_URL" ;;
    server)
      if [[ -z "$WHISPER_URL" ]]; then
        echo "Error: WHISPER_URL not set (server 방식은 음성 인식 서버 주소가 필요합니다)"
        exit 1
      fi ;;
    *)
      echo "Error: 알 수 없는 TRANSCRIBE_ENGINE: $TRANSCRIBE_ENGINE (local, openai, server 중 하나)"
      exit 1 ;;
  esac
fi

COOKIES_FILE="${COOKIES_FILE:-}"

# ── 의존성 체크 ──────────────────────────────────────────────
for cmd in jq ffmpeg curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' not found. brew install $cmd"
    exit 1
  fi
done

HAS_FZF=false
if command -v fzf &>/dev/null; then
  HAS_FZF=true
fi

HAS_MARKITDOWN=false
HAS_MARKITDOWN_OCR=false
if command -v markitdown &>/dev/null; then
  HAS_MARKITDOWN=true
  # OCR 플러그인 체크
  if python3 -c "import markitdown_ocr" 2>/dev/null; then
    HAS_MARKITDOWN_OCR=true
  fi
else
  echo "Warning: 'markitdown' not found. PDF→MD 변환 비활성화"
  echo "  설치: pip install 'markitdown[all]'"
  echo ""
fi

# ── API 요청 헬퍼 ────────────────────────────────────────────
api_request() {
  local url="$1"
  local cookie_args=()
  [[ -n "$COOKIES_FILE" ]] && cookie_args=(-b "$COOKIES_FILE")

  curl -sf ${cookie_args[@]+"${cookie_args[@]}"} \
    -H "Authorization: Bearer ${CANVAS_TOKEN:-}" \
    -H "Referer: https://canvas.ssu.ac.kr/" \
    "$url"
}

# ── JWT 디코딩 (base64 payload 추출) ─────────────────────────
decode_jwt_payload() {
  local token="$1"
  local payload
  payload=$(echo "$token" | cut -d'.' -f2)

  # base64 패딩 추가 (macOS 호환)
  local pad=$((4 - ${#payload} % 4))
  if [[ $pad -ne 4 ]]; then
    payload="${payload}$(printf '=%.0s' $(seq 1 $pad))"
  fi

  # URL-safe base64 → 표준 base64 변환 후 디코딩
  echo "$payload" | tr '_-' '/+' | base64 -d 2>/dev/null
}

# ── JWT 만료 확인 ────────────────────────────────────────────
is_jwt_expired() {
  local token="$1"
  local payload exp now

  payload=$(decode_jwt_payload "$token")
  [[ -z "$payload" ]] && return 0  # 디코딩 실패 = 만료로 간주

  exp=$(jq -r '.exp // empty' <<< "$payload" 2>/dev/null)
  [[ -z "$exp" || "$exp" == "null" ]] && return 0  # exp 없음 = 만료로 간주

  now=$(date +%s)
  [[ "$now" -ge "$exp" ]]
}

# ── 토큰 로드/저장/입력 ──────────────────────────────────────
load_or_prompt_token() {
  # 1. 환경변수에 이미 있으면 만료 확인
  if [[ -n "${CANVAS_TOKEN:-}" ]]; then
    if is_jwt_expired "$CANVAS_TOKEN"; then
      echo "Warning: 환경변수의 CANVAS_TOKEN이 만료되었습니다."
      unset CANVAS_TOKEN
    else
      return 0
    fi
  fi

  # 2. 파일에서 로드
  if [[ -f "$TOKEN_FILE" ]]; then
    CANVAS_TOKEN=$(cat "$TOKEN_FILE" | tr -d '[:space:]')
    if [[ -n "$CANVAS_TOKEN" ]] && ! is_jwt_expired "$CANVAS_TOKEN"; then
      export CANVAS_TOKEN
      return 0
    else
      echo "Warning: 저장된 토큰이 만료되었습니다."
      rm -f "$TOKEN_FILE"
      unset CANVAS_TOKEN
    fi
  fi

  # 3. 새로운 토큰 입력 요청
  echo ""
  echo "Canvas API 토큰이 필요합니다."
  echo "  Canvas 설정 > 액세스 토큰에서 발급받으세요."
  echo ""
  read -rp "CANVAS_TOKEN 입력: " input_token

  # trim
  CANVAS_TOKEN=$(echo "$input_token" | tr -d '[:space:]')

  if [[ -z "$CANVAS_TOKEN" ]]; then
    echo "Error: 토큰이 입력되지 않았습니다."
    return 1
  fi

  if is_jwt_expired "$CANVAS_TOKEN"; then
    echo "Error: 입력한 토큰이 이미 만료되었습니다."
    unset CANVAS_TOKEN
    return 1
  fi

  # 파일에 저장
  echo "$CANVAS_TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "토큰이 저장되었습니다: $TOKEN_FILE"
  export CANVAS_TOKEN
}

# ── 사용자 ID 가져오기 ───────────────────────────────────────
get_user_id() {
  local user_id

  # 방법 1: CANVAS_TOKEN JWT에서 user_login 추출
  if [[ -n "${CANVAS_TOKEN:-}" ]]; then
    local jwt_payload
    jwt_payload=$(decode_jwt_payload "$CANVAS_TOKEN")
    if [[ -n "$jwt_payload" ]]; then
      user_id=$(jq -r '.user_login // empty' <<< "$jwt_payload" 2>/dev/null)
      if [[ -n "$user_id" && "$user_id" != "null" ]]; then
        echo "$user_id"
        return 0
      fi
    fi
  fi

  echo "Error: JWT에서 사용자 ID를 추출할 수 없습니다. CANVAS_TOKEN 확인" >&2
  return 1
}

# ── 학기 목록 가져오기 ───────────────────────────────────────
fetch_terms() {
  local user_id="$1"
  api_request "${CANVAS_BASE}/api/v1/users/${user_id}/terms?include_invited_course_contained=true"
}

# ── 학기 선택 ────────────────────────────────────────────────
select_term() {
  local terms_json="$1"
  local term_count
  term_count=$(jq '.enrollment_terms | length' <<< "$terms_json")

  if [[ "$term_count" -eq 0 ]]; then
    echo "Error: 등록된 학기가 없습니다." >&2
    return 1
  fi

  if [[ "$term_count" -eq 1 ]]; then
    local term_id term_name
    term_id=$(jq -r '.enrollment_terms[0].id' <<< "$terms_json")
    term_name=$(jq -r '.enrollment_terms[0].name' <<< "$terms_json")
    echo "학기: $term_name (자동 선택)" >&2
    echo "$term_id"
    return 0
  fi

  echo "" >&2
  echo "=== 학기 선택 ===" >&2

  if $HAS_FZF; then
    local selected
    selected=$(jq -r '.enrollment_terms[] | "\(.id)\t\(.name)"' <<< "$terms_json" | \
      fzf --header="학기를 선택하세요" --delimiter='\t' --with-nth=2)
    [[ -z "$selected" ]] && return 1
    echo "$selected" | cut -f1
  else
    local i=1
    jq -r '.enrollment_terms[] | "\(.name)"' <<< "$terms_json" | while read -r name; do
      echo "  $i) $name" >&2
      ((i++))
    done

    local choice
    read -rp "선택 (1-$term_count): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "$term_count" ]]; then
      echo "Error: 잘못된 선택" >&2
      return 1
    fi

    jq -r ".enrollment_terms[$((choice-1))].id" <<< "$terms_json"
  fi
}

# ── 강의 목록 가져오기 ───────────────────────────────────────
fetch_courses() {
  local term_id="$1"
  api_request "${CANVAS_BASE}/api/v1/learn_activities/to_dos?term_ids[]=${term_id}"
}

# ── 강의명 가져오기 ──────────────────────────────────────────
get_course_name() {
  local course_id="$1"
  local course_json
  course_json=$(api_request "${CANVAS_BASE}/api/v1/courses/${course_id}")
  jq -r '.name // ""' <<< "$course_json"
}

# ── 강의 선택 (다중) ─────────────────────────────────────────
select_courses() {
  local todos_json="$1"
  local course_count
  course_count=$(jq '.to_dos | length' <<< "$todos_json")

  if [[ "$course_count" -eq 0 ]]; then
    echo "Error: 해당 학기에 등록된 강의가 없습니다." >&2
    return 1
  fi

  # 강의 정보 수집 (course_id + 이름)
  local courses_info
  courses_info=$(mktemp)

  echo "" >&2
  echo "강의 정보 로딩 중..." >&2

  jq -r '.to_dos[].course_id' <<< "$todos_json" | while read -r cid; do
    local cname
    cname=$(get_course_name "$cid")
    [[ -z "$cname" ]] && cname="강의 $cid"
    local incomplete
    incomplete=$(jq -r ".to_dos[] | select(.course_id == $cid) | .activities.total_incompleted_movies" <<< "$todos_json")
    echo -e "${cid}\t${cname}\t(미완료 영상: ${incomplete}개)"
  done > "$courses_info"

  echo "" >&2
  echo "=== 강의 선택 (다중 선택 가능) ===" >&2

  local selected_lines=()

  if $HAS_FZF; then
    local selected
    selected=$(cat "$courses_info" | \
      fzf --multi --header="강의 선택 (Tab: 개별 선택, Ctrl-A: 전체 선택, Enter: 확인)" \
          --delimiter='\t' --with-nth=2,3 \
          --bind='ctrl-a:select-all,ctrl-d:deselect-all' \
          --preview-window=hidden)
    rm -f "$courses_info"
    [[ -z "$selected" ]] && return 1

    while IFS= read -r line; do
      selected_lines+=("$line")
    done <<< "$selected"
  else
    local i=1
    while IFS=$'\t' read -r cid cname incomplete; do
      echo "  $i) $cname $incomplete" >&2
      ((i++))
    done < "$courses_info"

    echo "" >&2
    echo "선택할 강의 번호 입력 (쉼표로 구분, 예: 1,3,5 또는 all)" >&2
    local choice
    read -rp "선택: " choice

    local lines
    mapfile -t lines < "$courses_info"
    rm -f "$courses_info"

    if [[ "$choice" == "all" ]]; then
      selected_lines=("${lines[@]}")
    else
      IFS=',' read -ra choices <<< "$choice"
      for c in "${choices[@]}"; do
        c=$(echo "$c" | tr -d ' ')
        if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$c" -ge 1 ]] && [[ "$c" -le "${#lines[@]}" ]]; then
          selected_lines+=("${lines[$((c-1))]}")
        fi
      done
    fi
  fi

  if [[ ${#selected_lines[@]} -eq 0 ]]; then
    echo "Error: 강의가 선택되지 않았습니다." >&2
    return 1
  fi

  # id\tname 형식으로 출력
  for line in "${selected_lines[@]}"; do
    local cid cname
    cid=$(echo "$line" | cut -f1)
    cname=$(echo "$line" | cut -f2)
    printf '%s\t%s\n' "$cid" "$cname"
  done
}

# ── 인터랙티브 모드 실행 ─────────────────────────────────────
run_interactive() {
  echo ""
  echo "========================================"
  echo " Canvas LMS 다운로더 (인터랙티브 모드)"
  echo "========================================"

  # 0. 토큰 로드/검증
  load_or_prompt_token || exit 1

  # 1. 사용자 ID 가져오기
  echo ""
  echo "사용자 정보 확인 중..."
  local user_id
  user_id=$(get_user_id) || exit 1
  echo "사용자 ID: $user_id"

  # 2. 학기 목록 가져오기
  echo ""
  echo "학기 목록 로딩 중..."
  local terms_json
  terms_json=$(fetch_terms "$user_id")
  if [[ -z "$terms_json" ]]; then
    echo "Error: 학기 목록을 가져올 수 없습니다."
    exit 1
  fi

  # 3. 학기 선택
  local term_id
  term_id=$(select_term "$terms_json") || exit 1

  # 4. 강의 목록 가져오기
  echo ""
  echo "강의 목록 로딩 중..."
  local todos_json
  todos_json=$(fetch_courses "$term_id")
  if [[ -z "$todos_json" ]]; then
    echo "Error: 강의 목록을 가져올 수 없습니다."
    exit 1
  fi

  # 5. 강의 선택
  local selected_courses
  selected_courses=$(select_courses "$todos_json") || exit 1

  # 6. 선택된 강의 ID를 COURSE_IDS 배열에 추가
  local selected_names=()
  while IFS=$'\t' read -r cid cname; do
    COURSE_IDS+=("$cid")
    selected_names+=("$cname")
  done <<< "$selected_courses"

  echo ""
  echo "선택된 강의: ${#COURSE_IDS[@]}개"
  for i in "${!COURSE_IDS[@]}"; do
    echo "  - ${selected_names[$i]} (${COURSE_IDS[$i]})"
  done
}

# ── 주차 필터 체크 ───────────────────────────────────────────
is_week_included() {
  local week="$1"
  [[ -z "$WEEK_FILTER" ]] && return 0
  IFS=',' read -ra weeks <<< "$WEEK_FILTER"
  for w in "${weeks[@]}"; do
    [[ "$w" == "$week" ]] && return 0
  done
  return 1
}

# ── 파일을 마크다운으로 변환 ─────────────────────────────────
convert_to_markdown() {
  local src="$1"
  local md_path="${src%.*}.md"
  local name="$2"

  if [[ -f "$md_path" ]]; then
    echo "  [SKIP] MD 이미 존재: ${name%.*}.md"
    return 0
  fi

  if ! $HAS_MARKITDOWN; then
    return 0
  fi

  echo "  [MD] 변환 중: $name"
  if markitdown "$src" -o "$md_path" 2>/dev/null; then
    echo "  [MD] 완료: $md_path"
  else
    echo "  [MD] 실패: $name"
    rm -f "$md_path"
  fi
}

# ── 파일 다운로드 (자료) ─────────────────────────────────────
# ── 외부 링크 저장 (embed) ───────────────────────────────────
# 링크 항목의 뷰어 페이지는 버튼을 누르면 window.open("<원래 주소>")를 호출한다
save_link() {
  local content_id="$1"
  local dest="$2"
  local name="$3"

  if [[ -f "$dest" ]]; then
    echo "  [SKIP] 이미 존재: ${name}.webloc"
    return 0
  fi

  local cookie_args=()
  [[ -n "$COOKIES_FILE" ]] && cookie_args=(-b "$COOKIES_FILE")

  local link_url
  link_url=$(curl -sf ${cookie_args[@]+"${cookie_args[@]}"} "https://commons.ssu.ac.kr/em/${content_id}" \
    | grep -oE 'window\.open\("https?://[^"]+' | grep -v 'commons\.ssu\.ac\.kr' | head -1 | sed 's/^window\.open("//')

  if [[ -z "$link_url" ]]; then
    echo "  [LINK] 실패: 링크 주소를 찾지 못함 ($name)"
    mark_failed "link: $name" "링크 주소를 찾지 못함: 로그인이 만료되었거나 링크가 삭제되었을 수 있습니다"
    return 1
  fi

  write_webloc "$link_url" "$dest"
  echo "  [LINK] 완료: $link_url"
}

# .webloc은 Finder에서 더블클릭하면 브라우저로 열리는 macOS 링크 파일이다
write_webloc() {
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  local escaped="${url//&/&amp;}"
  escaped="${escaped//</&lt;}"
  cat > "$dest" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>URL</key>
  <string>${escaped}</string>
</dict>
</plist>
EOF
}

# ── 공지·과제 첨부파일 ───────────────────────────────────────
# Canvas 표준 API는 JSON 앞에 while(1);을 붙여 응답하므로 떼어 낸다
canvas_api_get() {
  local cookie_args=()
  [[ -n "$COOKIES_FILE" ]] && cookie_args=(-b "$COOKIES_FILE")
  curl -sf ${cookie_args[@]+"${cookie_args[@]}"} -H "Referer: https://canvas.ssu.ac.kr/" "https://canvas.ssu.ac.kr/api/v1/$1" | sed 's/^while(1);//'
}

download_attachments() {
  local course_id="$1"
  local course_dir="$2"

  echo ""
  echo "────────────────────────────────────────"
  echo " 공지·과제 첨부파일"
  echo "────────────────────────────────────────"

  local cookie_args=()
  [[ -n "$COOKIES_FILE" ]] && cookie_args=(-b "$COOKIES_FILE")

  local kind list refs links title_field body_field
  for kind in 공지 과제; do
    if [[ "$kind" == "공지" ]]; then
      list=$(canvas_api_get "courses/${course_id}/discussion_topics?only_announcements=true&per_page=100")
      title_field="title"; body_field="message"
    else
      list=$(canvas_api_get "courses/${course_id}/assignments?per_page=100")
      title_field="name"; body_field="description"
    fi

    if ! jq -e 'type == "array"' <<< "$list" >/dev/null 2>&1; then
      echo "Warning: ${kind} 목록을 가져오지 못했습니다 (로그인이 만료되었을 수 있습니다)"
      continue
    fi

    # 각 줄: 제목<TAB>파일 API 경로. 첨부 목록과 본문에 넣은 파일 링크를 모두 모은다
    refs=$(jq -r --arg cid "$course_id" --arg tf "$title_field" --arg bf "$body_field" '
      .[] | .[$tf] as $t
      | ([(.attachments // [])[] | "courses/\($cid)/files/\(.id)"]
         + [(.[$bf] // "") | scan("courses/[0-9]+/files/[0-9]+")])
      | unique[] | "\($t)\t\(.)"' <<< "$list")

    # 각 줄: 제목<TAB>링크 글자<TAB>주소. 본문의 외부 링크 (Canvas 파일과 메일 주소는 뺀다)
    links=$(jq -r --arg tf "$title_field" --arg bf "$body_field" '
      .[] | .[$tf] as $t
      | [(.[$bf] // "") | scan("<a [^>]*href=\"(https?://[^\"]+)\"[^>]*>(.*?)</a>"; "s")]
      | map({url: (.[0] | gsub("&amp;"; "&")), text: (.[1] | gsub("<[^>]+>"; "") | gsub("&nbsp;|\\s+"; " ") | gsub(" *\\(외부 사이트로 연결합니다\\.?\\)"; "") | gsub("^ +| +$"; ""))})
      | map(select(.url | test("/files/[0-9]+") | not))
      | unique_by(.url)[] | "\($t)\t\(.text)\t\(.url)"' <<< "$list")

    local item_title ref meta fname url http rc owner item_dir
    while IFS=$'\t' read -r item_title ref; do
      [[ -z "$ref" ]] && continue
      item_dir="${course_dir}/${kind}/$(tr '/' '-' <<< "$item_title")"
      meta=$(curl -s ${cookie_args[@]+"${cookie_args[@]}"} -H "Referer: https://canvas.ssu.ac.kr/" -w $'\n%{http_code}' \
        "https://canvas.ssu.ac.kr/api/v1/$ref")
      rc=$?
      http="${meta##*$'\n'}"
      meta=$(sed 's/^while(1);//' <<< "${meta%$'\n'*}")
      fname=$(jq -r '.display_name // empty' <<< "$meta" 2>/dev/null | tr '/' '-')
      url=$(jq -r '.url // empty' <<< "$meta" 2>/dev/null)
      if [[ -z "$fname" || -z "$url" ]]; then
        owner=$(grep -oE '^courses/[0-9]+' <<< "$ref" | cut -d/ -f2)
        if [[ "$http" == "401" || "$http" == "403" ]] && [[ "$owner" != "$course_id" ]]; then
          echo "  [SKIP] 첨부를 받을 수 없음: ${item_title} :: 다른 강의(${owner})에 올라간 파일이라 접근 권한이 없습니다. 교수님께 파일을 요청해 주세요"
        elif [[ "$http" == "401" || "$http" == "403" ]]; then
          echo "  [SKIP] 첨부를 받을 수 없음: ${item_title} :: 교수님이 파일을 비공개로 설정했거나 로그인이 만료되었습니다"
        elif [[ "$http" == "404" ]]; then
          echo "  [SKIP] 첨부를 받을 수 없음: ${item_title} :: 파일이 삭제되었습니다"
        else
          mark_failed "attach: $item_title" "$(curl_reason "$rc" "$http")"
        fi
        continue
      fi
      download_file "$url" "${item_dir}/${fname}" "$fname" "https://canvas.ssu.ac.kr/"
    done <<< "$refs"

    local text link_name
    while IFS=$'\t' read -r item_title text url; do
      [[ -z "$url" ]] && continue
      # 링크 글자가 없거나 주소 그대로면 도메인을 이름으로 쓴다
      link_name="$text"
      [[ -z "$link_name" || "$link_name" == http* ]] && link_name=$(sed -E 's#^https?://([^/]+).*#\1#' <<< "$url")
      link_name=$(tr '/:' '--' <<< "$link_name" | cut -c1-80)
      item_dir="${course_dir}/${kind}/$(tr '/' '-' <<< "$item_title")"
      # 이름이 같은 다른 링크는 번호를 붙여 따로 저장한다
      local n=1 dest="${item_dir}/${link_name}.webloc" existing
      while [[ -f "$dest" ]]; do
        existing=$(plutil -extract URL raw "$dest" 2>/dev/null)
        [[ "$existing" == "$url" ]] && break
        n=$((n + 1))
        dest="${item_dir}/${link_name} (${n}).webloc"
      done
      if [[ -f "$dest" ]]; then
        echo "  [SKIP] 이미 존재: $(basename "$dest")"
      else
        write_webloc "$url" "$dest"
        echo "  [LINK] 완료: $(basename "$dest") (${url%%\?*})"
      fi
    done <<< "$links"
  done
}

# Content-Disposition 헤더의 파일 이름 (없으면 빈 문자열)
remote_filename() {
  local cookie_args=()
  [[ -n "$COOKIES_FILE" ]] && cookie_args=(-b "$COOKIES_FILE")
  curl -sIL ${cookie_args[@]+"${cookie_args[@]}"} -H "Referer: $2" "$1" \
    | grep -i '^content-disposition:' | tail -1 | sed -E 's/.*filename="?([^";]*)"?.*/\1/' | tr -d '\r'
}

# 자료 파일 자리에 HTML 페이지가 저장됐는지 확인한다 (뷰어 페이지나 로그인 페이지)
is_html_page() {
  [[ "$1" != *.htm && "$1" != *.html ]] && head -c 512 "$1" 2>/dev/null | grep -qiE '<!doctype html|<html'
}

download_file() {
  local url="$1"
  local dest="$2"
  local name="$3"
  local referer="$4"
  local downloaded=false

  # 예전 버전은 뷰어 HTML을 자료 파일 이름으로 저장했으므로 그런 파일은 지우고 다시 받는다
  if [[ -f "$dest" ]] && is_html_page "$dest"; then
    echo "  [FILE] 잘못 저장된 파일 다시 받기: $name"
    rm -f "$dest" "${dest%.*}.md"
  fi

  if [[ -f "$dest" ]]; then
    echo "  [SKIP] 이미 존재: $name"
    downloaded=true
  else
    # 폴더가 없으면 생성
    local dest_dir
    dest_dir=$(dirname "$dest")
    [[ ! -d "$dest_dir" ]] && mkdir -p "$dest_dir"

    local cookie_args=()
    [[ -n "$COOKIES_FILE" ]] && cookie_args=(-b "$COOKIES_FILE")

    echo "  [FILE] 다운로드: $name"
    local http rc
    http=$(curl -sf -L --retry 3 --retry-delay 3 --connect-timeout 20 \
      ${cookie_args[@]+"${cookie_args[@]}"} -H "Referer: ${referer}" -w '%{http_code}' -o "${dest}.part" "$url")
    rc=$?
    if [[ $rc -eq 0 ]] && is_html_page "${dest}.part"; then
      echo "  [FILE] 실패: $name"
      mark_failed "file: $name" "파일 대신 웹페이지가 내려옴: 로그인이 만료되었을 수 있습니다. Canvas 로그인을 다시 해 주세요"
      rm -f "${dest}.part"
    elif [[ $rc -eq 0 ]] && mv "${dest}.part" "$dest"; then
      echo "  [FILE] 완료: $dest"
      downloaded=true
    else
      echo "  [FILE] 실패: $name"
      rm -f "${dest}.part"
      mark_failed "file: $name" "$(curl_reason "$rc" "$http" "$(dirname "$dest")")"
    fi
  fi

  # markitdown 지원 포맷이면 MD 변환
  if $downloaded && $HAS_MARKITDOWN; then
    local ext="${dest##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
      pdf|docx|doc|pptx|ppt|xlsx|xls|html|htm)
        convert_to_markdown "$dest" "$name"
        ;;
    esac
  fi
}

# ── 영상 다운로드 (다양한 content_type 지원) ─────────────────
download_video() {
  local content_id="$1"
  local dest_dir="$2"
  local title="$3"
  local out_path="${dest_dir}/${title}.mp4"

  if [[ -f "$out_path" ]]; then
    echo "  [SKIP] 이미 존재: $title.mp4" >&2
    echo "$out_path"
    return 0
  fi

  # 폴더가 없으면 생성
  [[ ! -d "$dest_dir" ]] && mkdir -p "$dest_dir"

  local cookie_args=()
  [[ -n "$COOKIES_FILE" ]] && cookie_args=(-b "$COOKIES_FILE")

  local content_xml rc http
  content_xml=$(curl -s --retry 3 --retry-delay 3 --connect-timeout 20 -w $'\n%{http_code}' ${cookie_args[@]+"${cookie_args[@]}"} \
    "https://commons.ssu.ac.kr/viewer/ssplayer/uniplayer_support/content.php?content_id=${content_id}")
  rc=$?
  http="${content_xml##*$'\n'}"
  content_xml="${content_xml%$'\n'*}"

  if [[ $rc -ne 0 || "$http" != "200" || -z "$content_xml" ]]; then
    echo "  [VIDEO] 실패: 영상 정보를 가져오지 못함" >&2
    if [[ $rc -eq 0 && "$http" == "200" ]]; then
      mark_failed "video: $title" "영상 정보가 비어 있음: 로그인이 만료되었을 수 있습니다. Canvas 로그인을 다시 해 주세요"
    else
      mark_failed "video: $title" "$(curl_reason "$rc" "$http")"
    fi
    return 1
  fi

  local mp4_url=""

  # 방법 1: everlec 방식 (method="progressive" + main_media)
  local media_uri media_file
  media_uri=$(echo "$content_xml" | grep -oE 'method="progressive" target="all">[^<]+' | sed 's/method="progressive" target="all">//')
  media_file=$(echo "$content_xml" | grep -oE '<main_media[^>]*>[^<]+' | sed 's/<main_media[^>]*>//')

  if [[ -n "$media_uri" && -n "$media_file" ]]; then
    mp4_url="${media_uri/\[MEDIA_FILE\]/$media_file}"
  fi

  # 방법 2: media_uri 태그에서 mp4 URL 추출 (movie, video1 등)
  if [[ -z "$mp4_url" ]]; then
    mp4_url=$(echo "$content_xml" | grep -oE '<media_uri>[^<]+\.mp4</media_uri>' | sed 's/<media_uri>//;s/<\/media_uri>//' | head -1)
  fi

  # 방법 3: media_uri CDATA에서 추출
  if [[ -z "$mp4_url" ]]; then
    mp4_url=$(echo "$content_xml" | grep -oE '<media_uri[^>]*><!\[CDATA\[[^]]+\]\]>' | sed 's/<media_uri[^>]*><!\[CDATA\[//;s/\]\]>//' | head -1)
  fi

  # 방법 4: content_uri CDATA에서 추출 (mp4로 끝나는 경우만)
  if [[ -z "$mp4_url" ]]; then
    local content_uri
    content_uri=$(echo "$content_xml" | grep -oE '<content_uri><!\[CDATA\[[^]]+\]\]>' | sed 's/<content_uri><!\[CDATA\[//;s/\]\]>//')
    [[ "$content_uri" == *.mp4 ]] && mp4_url="$content_uri"
  fi

  if [[ -z "$mp4_url" ]]; then
    echo "  [VIDEO] 실패: 영상 주소를 찾지 못함" >&2
    echo "  XML: $(echo "$content_xml" | head -c 500)" >&2
    mark_failed "video: $title" "영상 주소를 찾지 못함: 지원하지 않는 영상 형식이거나 아직 공개되지 않은 영상입니다"
    return 1
  fi

  echo "  [VIDEO] 다운로드: $title" >&2
  echo "  URL: $mp4_url" >&2

  # 지난번에 받다 끊긴 .part가 있으면 이어서 받는다
  local resume_args=()
  if [[ -s "${out_path}.part" ]]; then
    echo "  [VIDEO] 이어받기: $(( $(stat -f%z "${out_path}.part") / 1024 / 1024 ))MB부터" >&2
    resume_args=(-C -)
  fi

  http=$(curl -Lf --retry 3 --retry-delay 5 --connect-timeout 20 ${resume_args[@]+"${resume_args[@]}"} \
    ${cookie_args[@]+"${cookie_args[@]}"} \
    -H "Referer: https://commons.ssu.ac.kr/" \
    --progress-bar -w '%{http_code}' \
    -o "${out_path}.part" \
    "$mp4_url")
  rc=$?

  if [[ $rc -eq 0 ]] && mv "${out_path}.part" "$out_path"; then
    echo "  [VIDEO] 완료: $out_path" >&2
    echo "$out_path"
  else
    echo "  [VIDEO] 실패: $title" >&2
    # 연결이 끊긴 경우만 .part를 남겨 다음 실행에서 이어받는다
    case "$rc" in
      18|28|56|92) ;;
      *) rm -f "${out_path}.part" ;;
    esac
    mark_failed "video: $title" "$(curl_reason "$rc" "$http" "$dest_dir")"
  fi
}

# ── 영상 압축 (200MB 이하) ──────────────────────────────────
compress_video() {
  local video_path="$1"
  local max_mb="$2"

  if [[ ! -f "$video_path" ]]; then
    return 0
  fi

  local size
  size=$(stat -f%z "$video_path" 2>/dev/null || stat -c%s "$video_path" 2>/dev/null)
  local max_bytes=$((max_mb * 1024 * 1024))

  if [[ $size -le $max_bytes ]]; then
    echo "  [COMPRESS] 이미 ${max_mb}MB 이하 ($(( size / 1024 / 1024 ))MB) — 건너뜀"
    return 0
  fi

  echo "  [COMPRESS] 압축 시작 ($(( size / 1024 / 1024 ))MB → ${max_mb}MB 이하)"

  local duration
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_path" 2>/dev/null)
  duration=${duration%.*}

  if [[ -z "$duration" || "$duration" -eq 0 ]]; then
    echo "  [COMPRESS] 실패: 영상 길이를 알 수 없음"
    mark_failed "compress: $video_path" "영상 길이를 알 수 없음: 영상 파일이 손상되었을 수 있습니다"
    return 1
  fi

  # 목표 비트레이트 계산 (총 비트레이트 = 파일크기 / 시간)
  # 오디오 128kbps 할당, 나머지 비디오 + 5% 안전 마진
  local audio_bitrate=128000

  # 15% 안전 마진 적용
  local safe_bytes=$(( max_bytes * 85 / 100 ))
  local safe_total_bitrate=$(( safe_bytes * 8 / duration ))
  local safe_video_bitrate=$(( safe_total_bitrate - audio_bitrate ))

  if [[ $safe_video_bitrate -lt 100000 ]]; then
    echo "  [COMPRESS] 실패: 영상이 너무 길어 ${max_mb}MB로 압축 불가"
    mark_failed "compress: $video_path" "영상이 너무 길어 ${max_mb}MB로 줄일 수 없음: 목표 크기를 늘려 주세요"
    return 1
  fi

  local compressed_path="${video_path%.mp4}_compressed.mp4"
  local passlog="${video_path%.mp4}_passlog"

  echo "  [COMPRESS] 압축 중... (목표: ${max_mb}MB)"
  local ffmpeg_err
  ffmpeg_err=$(mktemp)

  # 15% 안전 마진으로 1-pass 압축 (빠름)
  if ffmpeg -nostdin -err_detect ignore_err -i "$video_path" \
    -c:v libx264 -b:v "${safe_video_bitrate}" -maxrate "$((safe_video_bitrate * 13 / 10))" -bufsize "$((safe_video_bitrate * 2))" \
    -c:a aac -b:a 128k \
    -preset fast -threads ${FFMPEG_THREADS:-0} -movflags +faststart \
    -y "$compressed_path" -loglevel error 2>"$ffmpeg_err"; then

    local new_size
    new_size=$(stat -f%z "$compressed_path" 2>/dev/null || stat -c%s "$compressed_path" 2>/dev/null)

    # 초과 시 더 낮은 비트레이트로 재시도 (1회)
    if [[ $new_size -gt $max_bytes ]]; then
      echo "  [COMPRESS] 초과 ($(( new_size / 1024 / 1024 ))MB) — 재압축 중..."
      local retry_bitrate=$(( safe_video_bitrate * max_bytes / new_size * 85 / 100 ))

      ffmpeg -nostdin -err_detect ignore_err -i "$video_path" \
        -c:v libx264 -b:v "${retry_bitrate}" -maxrate "$((retry_bitrate * 12 / 10))" -bufsize "$((retry_bitrate * 2))" \
        -c:a aac -b:a 128k \
        -preset fast -threads ${FFMPEG_THREADS:-0} -movflags +faststart \
        -y "$compressed_path" -loglevel error 2>/dev/null

      new_size=$(stat -f%z "$compressed_path" 2>/dev/null || stat -c%s "$compressed_path" 2>/dev/null)
    fi

    # 원본 교체
    mv "$compressed_path" "$video_path"
    echo "  [COMPRESS] 완료: $(( size / 1024 / 1024 ))MB → $(( new_size / 1024 / 1024 ))MB"
  else
    echo "  [COMPRESS] 실패: ffmpeg 오류"
    rm -f "$compressed_path"
    mark_failed "compress: $video_path" "ffmpeg 오류: $(last_error_line "$ffmpeg_err")"
  fi
  rm -f "$ffmpeg_err"
}

# ── Whisper transcribe ───────────────────────────────────────
# ── Whisper API 호출 ─────────────────────────────────────────
call_whisper() {
  local audio_file="$1"
  local response_tmp="/tmp/whisper_response_$$.txt"
  local format="text"
  $SAVE_SRT && format="srt"

  # OpenAI 키는 OpenAI 방식에서만 보낸다 (다른 서버 주소로 키가 새지 않게)
  local auth_args=()
  [[ "$TRANSCRIBE_ENGINE" == "openai" ]] && auth_args=(-H "Authorization: Bearer $OPENAI_API_KEY")

  local http_status
  http_status=$(curl -s \
    -o "$response_tmp" \
    -w "%{http_code}" \
    ${auth_args[@]+"${auth_args[@]}"} \
    -F file="@$audio_file" \
    -F model="$WHISPER_MODEL" \
    -F response_format="$format" \
    -F language="ko" \
    "$WHISPER_URL")

  if [[ "$http_status" == "200" ]]; then
    cat "$response_tmp"
    rm -f "$response_tmp"
    return 0
  fi
  # $(...) 안에서 불리므로 원인은 파일로 넘긴다
  local reason
  case "$http_status" in
    000) reason="음성 인식 서버에 연결할 수 없음: 인터넷 연결이나 서버 주소를 확인해 주세요" ;;
    401) reason="API 키가 올바르지 않음 (HTTP 401): 설정의 OpenAI API Key를 확인해 주세요" ;;
    413) reason="오디오 파일이 너무 큼 (HTTP 413)" ;;
    429) reason="사용 한도 초과 (HTTP 429): OpenAI 결제 잔액이나 사용량 한도를 확인해 주세요" ;;
    *) reason="음성 인식 서버 오류 (HTTP $http_status): $(head -c 200 "$response_tmp" | tr '\n' ' ')" ;;
  esac
  echo "$reason" > "${TRANSCRIBE_ERROR_FILE:-/dev/null}"
  rm -f "$response_tmp"
  return 1
}

# ── 무료 음성 인식 (mlx-whisper, Apple Silicon) ──────────────
# 디렉터리 생성은 원자적이므로 잠금으로 쓴다. 잠근 프로세스가 죽었으면 잠금을 치운다
acquire_lock() {
  local lock="$1"
  until mkdir "$lock" 2>/dev/null; do
    local owner
    owner=$(cat "$lock/pid" 2>/dev/null)
    if [[ -n "$owner" ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$lock"
      continue
    fi
    sleep 2
  done
  echo $$ > "$lock/pid"
}

release_lock() { rm -rf "$1"; }

ensure_local_whisper() {
  [[ -x "$WHISPER_VENV/bin/mlx_whisper" ]] && return 0

  if [[ "$(uname -m)" != "arm64" ]]; then
    echo "  [TRANSCRIBE] 실패: 무료 음성 인식은 Apple Silicon Mac에서만 동작합니다 (OpenAI 방식을 쓰세요)"
    TRANSCRIBE_ERROR="무료 음성 인식은 Apple Silicon Mac에서만 동작합니다: 설정에서 OpenAI 방식을 골라 주세요"
    return 1
  fi

  # 여러 강의를 병렬로 받을 때 한 번만 설치하도록 잠근다
  mkdir -p "$(dirname "$WHISPER_VENV")"
  acquire_lock "${WHISPER_VENV}.install.lock"
  if [[ ! -x "$WHISPER_VENV/bin/mlx_whisper" ]]; then
    echo "  [TRANSCRIBE] 무료 음성 인식 엔진 설치 중 (처음 한 번만, 1~2분)"
    rm -rf "$WHISPER_VENV"
    local installed=false
    if command -v uv >/dev/null 2>&1; then
      uv venv -q -p 3.13 "$WHISPER_VENV" && uv pip install -q -p "$WHISPER_VENV/bin/python" mlx-whisper && installed=true
    else
      local py
      for py in python3.13 python3.12 python3.11 python3.10; do
        command -v "$py" >/dev/null 2>&1 || continue
        "$py" -m venv "$WHISPER_VENV" && "$WHISPER_VENV/bin/pip" install -q mlx-whisper && installed=true
        break
      done
    fi
    if ! $installed; then
      rm -rf "$WHISPER_VENV"
      echo "  [TRANSCRIBE] 실패: 엔진 설치 실패 (Python 3.10 이상 또는 uv가 필요합니다)"
      TRANSCRIBE_ERROR="음성 인식 엔진 설치 실패: 인터넷 연결을 확인하고, 설정 탭의 필수 도구에서 uv가 설치되어 있는지 확인해 주세요"
    fi
  fi
  release_lock "${WHISPER_VENV}.install.lock"
  [[ -x "$WHISPER_VENV/bin/mlx_whisper" ]]
}

# 결과를 out_dir/<오디오 이름>.txt, .srt로 남긴다
transcribe_local() {
  local audio_file="$1"
  local out_dir="$2"
  ensure_local_whisper || return 1

  # 모델 하나가 메모리를 수 GB 쓰므로, 여러 강의를 병렬로 받아도 음성 인식은 하나씩 처리한다
  local lock="${WHISPER_VENV}.run.lock"
  [[ -d "$lock" ]] && echo "  [TRANSCRIBE] 다른 강의의 음성 인식이 끝나기를 기다리는 중..."
  acquire_lock "$lock"
  echo "  [TRANSCRIBE] 내 Mac에서 처리 중 (무료, 처음에는 모델 1.6GB를 내려받습니다)"
  "$WHISPER_VENV/bin/mlx_whisper" "$audio_file" \
    --model "$LOCAL_WHISPER_MODEL" --language ko \
    --output-format all --output-dir "$out_dir" --verbose False \
    < /dev/null > /dev/null 2> "${out_dir}/whisper.err"
  local rc=$?
  release_lock "$lock"
  if [[ $rc -ne 0 ]]; then
    case "$rc" in
      137) TRANSCRIBE_ERROR="메모리가 부족해 음성 인식이 중단됨: 다른 앱을 닫고 다시 시도해 주세요" ;;
      *) TRANSCRIBE_ERROR="음성 인식 엔진 오류: $(last_error_line "${out_dir}/whisper.err")" ;;
    esac
  fi
  return $rc
}

# SRT 시각에 offset초를 더하고 번호를 start부터 다시 매긴다 (분할한 청크를 이어 붙이기 위해)
shift_srt() {
  tr -d '\r' | awk -v off="$1" -v idx="$2" '
    function sec(ts,  a) { split(ts, a, /[:,]/); return a[1] * 3600 + a[2] * 60 + a[3] + a[4] / 1000 }
    function fmt(t,  ms, h, m, s) {
      ms = int(t * 1000 + 0.5)
      h = int(ms / 3600000); ms -= h * 3600000
      m = int(ms / 60000); ms -= m * 60000
      s = int(ms / 1000); ms -= s * 1000
      return sprintf("%02d:%02d:%02d,%03d", h, m, s, ms)
    }
    BEGIN { RS = ""; FS = "\n" }
    $2 ~ / --> / {
      split($2, t, / --> /)
      print idx++
      print fmt(sec(t[1]) + off) " --> " fmt(sec(t[2]) + off)
      for (i = 3; i <= NF; i++) print $i
      print ""
    }'
}

# SRT에서 번호와 시각을 빼고 자막 문장만 남긴다
srt_to_text() {
  awk 'BEGIN { RS = ""; FS = "\n" } { line = ""; for (i = 3; i <= NF; i++) line = line (i > 3 ? " " : "") $i; print line }'
}

transcribe_video() {
  local video_path="$1"
  local out_txt="$2"
  local title="$3"
  local out_srt="${out_txt%.txt}.srt"

  if [[ -f "$out_txt" ]] && { ! $SAVE_SRT || [[ -f "$out_srt" ]]; }; then
    echo "  [SKIP] 이미 transcribe됨: $title"
    return 0
  fi

  if [[ -z "$video_path" || ! -f "$video_path" ]]; then
    echo "  [TRANSCRIBE] 건너뜀 (영상 없음)"
    return 0
  fi

  echo "  [TRANSCRIBE] 시작: $title"

  local tmp_dir="/tmp/transcribe_$$"
  mkdir -p "$tmp_dir"
  TRANSCRIBE_ERROR=""
  TRANSCRIBE_ERROR_FILE="${tmp_dir}/error.txt"

  # 전체 오디오 추출
  local audio_full="${tmp_dir}/full.mp3"
  ffmpeg -nostdin -i "$video_path" -vn -ar 16000 -ac 1 -b:a 32k "$audio_full" -y -loglevel error 2> "${tmp_dir}/ffmpeg.err"

  if [[ ! -s "$audio_full" ]]; then
    echo "  [TRANSCRIBE] 실패: 오디오 추출 실패"
    local why
    why=$(last_error_line "${tmp_dir}/ffmpeg.err")
    rm -rf "$tmp_dir"
    mark_failed "transcribe: $title" "영상에서 소리를 뽑지 못함: ${why:-소리가 없는 영상이거나 파일이 손상되었습니다}"
    return 1
  fi

  local size
  size=$(stat -f%z "$audio_full" 2>/dev/null || stat -c%s "$audio_full")
  local max_size=24000000  # 24MB

  local final_text=""
  local chunk_failed=false

  if [[ "$TRANSCRIBE_ENGINE" == "local" ]]; then
    # 로컬 엔진은 파일 크기 제한이 없으므로 나누지 않는다
    local base="${tmp_dir}/$(basename "${audio_full%.*}")"
    if transcribe_local "$audio_full" "$tmp_dir"; then
      if $SAVE_SRT; then
        final_text=$(cat "${base}.srt" 2>/dev/null)
      else
        final_text=$(cat "${base}.txt" 2>/dev/null)
      fi
    else
      chunk_failed=true
    fi
  elif [[ $size -le $max_size ]]; then
    # 24MB 이하: 그대로 처리
    echo "  [TRANSCRIBE] 단일 처리 ($(( size / 1024 / 1024 ))MB)"
    final_text=$(call_whisper "$audio_full") || chunk_failed=true
    $SAVE_SRT && final_text=$(shift_srt 0 1 <<< "$final_text")
  else
    # 24MB 초과: 24MB 단위로 분할
    echo "  [TRANSCRIBE] 분할 처리 ($(( size / 1024 / 1024 ))MB)"

    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$audio_full" 2>/dev/null)
    duration=${duration%.*}

    local sec_per_byte=$(echo "scale=6; $duration / $size" | bc)
    local chunk_sec=$(echo "$sec_per_byte * $max_size" | bc | cut -d. -f1)
    local total_chunks=$(( (duration + chunk_sec - 1) / chunk_sec ))
    local chunk_num=1
    local offset=0

    while [[ $offset -lt $duration ]]; do
      local audio_chunk="${tmp_dir}/chunk_${chunk_num}.mp3"

      echo "  [TRANSCRIBE] 청크 ${chunk_num}/${total_chunks} (${offset}초~)..."
      ffmpeg -nostdin -i "$audio_full" -ss "$offset" -t "$chunk_sec" -c copy "$audio_chunk" -y -loglevel error

      if [[ -f "$audio_chunk" ]]; then
        local chunk_text
        if chunk_text=$(call_whisper "$audio_chunk"); then
          # 청크 안의 시각은 0초부터 시작하므로 청크 시작 위치만큼 민다 (번호는 저장할 때 다시 매긴다)
          $SAVE_SRT && chunk_text=$(shift_srt "$offset" 1 <<< "$chunk_text")$'\n'
          [[ -n "$chunk_text" ]] && final_text="${final_text}${chunk_text}"$'\n'
        else
          chunk_failed=true
        fi
        rm -f "$audio_chunk"
      else
        chunk_failed=true
      fi

      offset=$((offset + chunk_sec))
      chunk_num=$((chunk_num + 1))
    done
  fi

  [[ -z "$TRANSCRIBE_ERROR" && -s "$TRANSCRIBE_ERROR_FILE" ]] && TRANSCRIBE_ERROR=$(head -1 "$TRANSCRIBE_ERROR_FILE")
  rm -rf "$tmp_dir"

  # 일부만 저장하면 다음 실행에서 "이미 transcribe됨"으로 건너뛰므로 전부 성공했을 때만 쓴다
  if $chunk_failed; then
    echo "  [TRANSCRIBE] 실패: 음성 인식 실패 (다음 실행 때 다시 시도)"
    mark_failed "transcribe: $title" "${TRANSCRIBE_ERROR:-음성 인식 실패}"
  elif $SAVE_SRT && ! grep -q ' --> ' <<< "$final_text"; then
    echo "  [TRANSCRIBE] 실패: 서버가 srt 형식을 돌려주지 않음 (자막 저장을 끄거나 다른 서버를 쓰세요)"
    mark_failed "transcribe: $title" "서버가 srt 자막 형식을 지원하지 않음: 자막 저장을 끄거나 다른 서버를 써 주세요"
  elif [[ -n "$final_text" ]]; then
    if $SAVE_SRT; then
      shift_srt 0 1 <<< "$final_text" > "$out_srt"
      srt_to_text <<< "$final_text" > "$out_txt"
      echo "  [TRANSCRIBE] 완료: $out_srt"
    else
      echo "$final_text" > "$out_txt"
    fi
    echo "  [TRANSCRIBE] 완료: $out_txt"
  else
    echo "  [TRANSCRIBE] 실패: 결과 없음"
    mark_failed "transcribe: $title" "인식된 말소리가 없음: 소리가 없거나 너무 작은 영상일 수 있습니다"
  fi
}

# ── 강의 처리 함수 ───────────────────────────────────────────
process_course() {
  local course_id="$1"
  local json_file="$2"   # 비어있으면 API fetch

  local json_tmp
  json_tmp=$(mktemp)

  # JSON 로드
  if [[ -n "$json_file" ]]; then
    echo "JSON 파일 사용: $json_file"
    cp "$json_file" "$json_tmp"
  else
    local api_url="${CANVAS_BASE}/api/v1/courses/${course_id}/modules?include_detail=true"
    echo "Canvas API fetch 중... (course_id: $course_id)"

    local module_cookie_args=()
    [[ -n "$COOKIES_FILE" ]] && module_cookie_args=(-b "$COOKIES_FILE")

    local http_status
    local max_retries=3
    local retry=0

    while true; do
      http_status=$(curl -s -o "$json_tmp" -w "%{http_code}" \
        ${module_cookie_args[@]+"${module_cookie_args[@]}"} \
        -H "Authorization: Bearer ${CANVAS_TOKEN:-}" \
        -H "Referer: https://canvas.ssu.ac.kr/" \
        "$api_url")

      if [[ "$http_status" == "200" ]]; then
        break
      elif [[ "$http_status" == "401" ]]; then
        echo "Error: 인증 실패: 로그인이 만료되었습니다. 설정 탭에서 Canvas 로그인을 다시 해 주세요"
        rm -f "$json_tmp"; return 1
      elif [[ "$http_status" == "404" ]]; then
        echo "Error: 강의를 찾을 수 없음 — course_id($course_id) 확인"
        rm -f "$json_tmp"; return 1
      else
        retry=$((retry + 1))
        if [[ $retry -ge $max_retries ]]; then
          echo "Error: API 요청 실패 (HTTP $http_status) — ${max_retries}회 재시도 후 포기"
          echo "응답: $(head -c 300 "$json_tmp")"
          rm -f "$json_tmp"; return 1
        fi
        local wait_sec=$((retry * 3))
        echo "Warning: API 요청 실패 (HTTP $http_status) — ${wait_sec}초 후 재시도 (${retry}/${max_retries})"
        sleep "$wait_sec"
      fi
    done
  fi

  if ! jq empty "$json_tmp" 2>/dev/null; then
    echo "Error: 유효하지 않은 JSON"
    echo "내용: $(head -c 200 "$json_tmp")"
    rm -f "$json_tmp"; return 1
  fi

  # 강의명 fetch
  local course_name=""
  local course_tmp
  course_tmp=$(mktemp)
  local course_cookie_args=()
  [[ -n "$COOKIES_FILE" ]] && course_cookie_args=(-b "$COOKIES_FILE")

  local course_http
  course_http=$(curl -s \
    -o "$course_tmp" \
    -w "%{http_code}" \
    ${course_cookie_args[@]+"${course_cookie_args[@]}"} \
    -H "Referer: https://canvas.ssu.ac.kr/" \
    -H "Authorization: Bearer ${CANVAS_TOKEN:-}" \
    "https://canvas.ssu.ac.kr/learningx/api/v1/courses/${course_id}")
  course_name=$(jq -r '.name // ""' "$course_tmp" 2>/dev/null | tr '/' '-' || true)
  rm -f "$course_tmp"

  local course_dir
  if [[ -n "$course_name" ]]; then
    echo "강의명: $course_name"
    course_dir="${OUTPUT_DIR}/${course_name}"
  else
    echo "강의명 추출 실패 (HTTP $course_http) — course_id로 대체"
    course_dir="${OUTPUT_DIR}/${course_id}"
  fi
  mkdir -p "$course_dir"

  local module_count
  module_count=$(jq 'length' "$json_tmp")
  echo "모듈 ${module_count}개 로드 완료"

  echo ""
  echo "========================================"
  echo " ${course_name:-$course_id}"
  echo " 출력: $course_dir"
  [[ -n "$WEEK_FILTER" ]] && echo " 주차 필터: $WEEK_FILTER"
  echo "========================================"

  # 첨부는 작아서 금방 끝나므로, 오래 걸리는 영상보다 먼저 받는다
  if $DO_ATTACH && [[ -n "$course_id" ]]; then
    download_attachments "$course_id" "$course_dir"
  fi

  jq -c '.[]' "$json_tmp" | while read -r module; do
    local week week_title item_count week_dir
    week=$(jq <<< "$module" -r '.week_position // ""')
    week_title=$(jq <<< "$module" -r '.title' | tr '/' '-')
    # 일부 강의는 week_position이 비어 있으므로 "4주차" 같은 제목에서 주차 번호를 얻는다
    if [[ -z "$week" && "$week_title" =~ ([0-9]+)주차 ]]; then
      week="${BASH_REMATCH[1]}"
    fi

    is_week_included "$week" || continue

    item_count=$(jq <<< "$module" '.module_items | length')
    [[ "$item_count" -eq 0 ]] && continue

    week_dir="${course_dir}/${week_title}"

    echo ""
    echo "────────────────────────────────────────"
    echo " ${week_title}"
    echo "────────────────────────────────────────"

    jq <<< "$module" -c '.module_items[]?' | while read -r item; do
      local content_type opened title inner_type
      content_type=$(jq <<< "$item" -r '.content_type')
      [[ "$content_type" == "wiki_page" || "$content_type" == "quiz" || "$content_type" == "discussion" || "$content_type" == "assignment" ]] && continue

      opened=$(jq <<< "$item" -r '.content_data.opened // false')
      $OPENED_ONLY && [[ "$opened" != "true" ]] && continue

      title=$(jq <<< "$item" -r '.title' | tr '/' '-')
      inner_type=$(jq <<< "$item" -r '.content_data.item_content_data.content_type')

      echo ""
      echo " 항목: $title"
      echo " 유형: $inner_type | 공개: $opened"

      case "$inner_type" in
        everlec|mp4|movie|readystream)
          $DO_VIDEO || continue
          local local_content_id
          local_content_id=$(jq <<< "$item" -r '.content_data.item_content_data.content_id // ""')
          [[ -z "$local_content_id" || "$local_content_id" == "not_open" ]] && \
            echo "  [SKIP] content_id 없음 (미공개)" && continue

          local video_path
          if ! $KEEP_VIDEO; then
            $DO_TRANSCRIBE || continue
            local out_txt="${week_dir}/${title}.txt"
            if [[ -f "$out_txt" ]] && { ! $SAVE_SRT || [[ -f "${out_txt%.txt}.srt" ]]; }; then
              echo "  [SKIP] 이미 transcribe됨: $title"
              continue
            fi
            mkdir -p "$week_dir"
            # 예전에 받아 둔 영상이 있으면 다시 받지 않는다
            if [[ -f "${week_dir}/${title}.mp4" ]]; then
              transcribe_video "${week_dir}/${title}.mp4" "$out_txt" "$title"
            else
              local tmp_video_dir
              tmp_video_dir=$(mktemp -d)
              video_path=$(download_video "$local_content_id" "$tmp_video_dir" "$title")
              [[ -n "$video_path" ]] && transcribe_video "$video_path" "$out_txt" "$title"
              rm -rf "$tmp_video_dir"
            fi
            continue
          fi

          video_path=$(download_video "$local_content_id" "$week_dir" "$title")

          if $DO_COMPRESS && [[ -n "$video_path" ]]; then
            compress_video "$video_path" "$COMPRESS_MAX_MB"
          fi

          if $DO_TRANSCRIBE && [[ -n "$video_path" ]]; then
            transcribe_video "$video_path" "${week_dir}/${title}.txt" "$title"
          fi
          ;;

        file|pdf)
          $DO_FILE || continue
          local file_content_id ext fname
          file_content_id=$(jq <<< "$item" -r '.content_data.item_content_data.content_id // ""')
          [[ -z "$file_content_id" || "$file_content_id" == "not_open" ]] && \
            echo "  [SKIP] content_id 없음 (미공개)" && continue

          # view_url(/em/<id>)은 문서 뷰어 HTML이므로, 뷰어의 다운로드 버튼과 같은 주소로 원본을 받는다
          local file_url="https://commons.ssu.ac.kr/index.php?module=xn_media_content2013&act=dispXn_media_content2013DownloadContent&content_id=${file_content_id}"
          local file_referer="https://commons.ssu.ac.kr/em/${file_content_id}"

          ext="${inner_type}"
          fname=$(jq <<< "$item" -r '.content_data.item_content_data.file_name // ""')
          # 강의 정보에 파일 이름이 없으면 서버가 내려주는 파일 이름에서 확장자를 얻는다
          [[ "$fname" != *.* ]] && fname=$(remote_filename "$file_url" "$file_referer")
          [[ "$fname" == *.* ]] && ext="${fname##*.}"
          download_file "$file_url" "${week_dir}/${title}.${ext}" "$title" "$file_referer"
          ;;

        embed)
          $DO_FILE || continue
          local embed_id
          embed_id=$(jq <<< "$item" -r '.content_data.item_content_data.content_id // ""')
          [[ -z "$embed_id" || "$embed_id" == "not_open" ]] && \
            echo "  [SKIP] content_id 없음 (미공개)" && continue
          save_link "$embed_id" "${week_dir}/${title}.webloc" "$title"
          ;;

        *)
          echo "  [SKIP] 알 수 없는 유형: $inner_type"
          ;;
      esac
    done
  done

  rm -f "$json_tmp"
  echo ""
  echo " 완료: $course_dir"
}

# ── 메인 ─────────────────────────────────────────────────────

# 인터랙티브 모드
if $INTERACTIVE_MODE; then
  run_interactive
fi

mkdir -p "$OUTPUT_DIR"

if [[ -n "$JSON_FILE" ]]; then
  process_course "" "$JSON_FILE" || mark_failed "json: $JSON_FILE" "강의 정보를 읽지 못함"
else
  for course_id in "${COURSE_IDS[@]}"; do
    echo ""
    echo "########################################"
    echo " 강의 처리: $course_id"
    echo "########################################"
    process_course "$course_id" "" || mark_failed "course: $course_id" "강의 정보를 가져오지 못함 (위의 Error 줄을 확인해 주세요)"
  done
fi

echo ""
echo "========================================"
echo " 전체 완료. 출력: $OUTPUT_DIR"
echo "========================================"

if [[ -s "$FAIL_LOG" ]]; then
  echo "Warning: 실패 $(wc -l < "$FAIL_LOG" | tr -d ' ')건"
  exit 1
fi
