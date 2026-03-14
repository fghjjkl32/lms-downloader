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

# ── 기본값 ──────────────────────────────────────────────────
CANVAS_BASE="https://canvas.ssu.ac.kr/learningx"
COURSE_IDS=()
OUTPUT_DIR="./lms_output"
JSON_FILE=""
WEEK_FILTER=""
DO_VIDEO=true
DO_FILE=true
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
  --no-file        자료 파일 다운로드 건너뜀
  --no-transcribe  transcribe 건너뜀 (영상만 다운로드)
  --opened-only    opened:true 항목만 처리 (기본값)
  --all            미공개 포함 전체 시도
  -h, --help       이 도움말 출력

환경변수:
  OPENAI_API_KEY   Whisper API 키 (transcribe 시 필요)
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
    --no-file) DO_FILE=false; shift ;;
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

if $DO_TRANSCRIBE && [[ -z "${OPENAI_API_KEY:-}" ]]; then
  echo "Error: OPENAI_API_KEY not set (transcribe 끄려면 --no-transcribe)"
  exit 1
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

  curl -sf "${cookie_args[@]}" \
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
download_file() {
  local url="$1"
  local dest="$2"
  local name="$3"
  local downloaded=false

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
    if curl -sf -L "${cookie_args[@]}" -o "$dest" "$url"; then
      echo "  [FILE] 완료: $dest"
      downloaded=true
    else
      echo "  [FILE] 실패: $url"
      rm -f "$dest"
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

  local content_xml
  content_xml=$(curl -sf "${cookie_args[@]}" \
    "https://commons.ssu.ac.kr/viewer/ssplayer/uniplayer_support/content.php?content_id=${content_id}")

  if [[ -z "$content_xml" ]]; then
    echo "  [VIDEO] 실패: content.php 응답 없음 (쿠키 확인)" >&2
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
    echo "  [VIDEO] 실패: XML에서 media URL 추출 실패" >&2
    echo "  XML: $(echo "$content_xml" | head -c 500)" >&2
    return 1
  fi

  echo "  [VIDEO] 다운로드: $title" >&2
  echo "  URL: $mp4_url" >&2

  if curl -Lf "${cookie_args[@]}" \
    -H "Referer: https://commons.ssu.ac.kr/" \
    --progress-bar \
    -o "$out_path" \
    "$mp4_url"; then
    echo "  [VIDEO] 완료: $out_path" >&2
    echo "$out_path"
  else
    echo "  [VIDEO] 실패: $mp4_url" >&2
    rm -f "$out_path"
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
    return 1
  fi

  # 목표 비트레이트 계산 (총 비트레이트 = 파일크기 / 시간)
  # 오디오 128kbps 할당, 나머지 비디오
  local target_total_bitrate=$(( max_bytes * 8 / duration ))
  local audio_bitrate=128000
  local video_bitrate=$(( target_total_bitrate - audio_bitrate ))

  if [[ $video_bitrate -lt 100000 ]]; then
    echo "  [COMPRESS] 실패: 영상이 너무 길어 ${max_mb}MB로 압축 불가"
    return 1
  fi

  local compressed_path="${video_path%.mp4}_compressed.mp4"

  if ffmpeg -i "$video_path" \
    -c:v libx264 -b:v "${video_bitrate}" -maxrate "$((video_bitrate * 2))" -bufsize "$((video_bitrate * 4))" \
    -c:a aac -b:a 128k \
    -preset fast -movflags +faststart \
    -y "$compressed_path" -loglevel warning 2>&1; then

    local new_size
    new_size=$(stat -f%z "$compressed_path" 2>/dev/null || stat -c%s "$compressed_path" 2>/dev/null)

    # 원본 교체
    mv "$compressed_path" "$video_path"
    echo "  [COMPRESS] 완료: $(( size / 1024 / 1024 ))MB → $(( new_size / 1024 / 1024 ))MB"
  else
    echo "  [COMPRESS] 실패: ffmpeg 오류"
    rm -f "$compressed_path"
  fi
}

# ── Whisper transcribe ───────────────────────────────────────
# ── Whisper API 호출 ─────────────────────────────────────────
call_whisper() {
  local audio_file="$1"
  local response_tmp="/tmp/whisper_response_$$.txt"

  local http_status
  http_status=$(curl -s \
    -o "$response_tmp" \
    -w "%{http_code}" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -F file="@$audio_file" \
    -F model="whisper-1" \
    -F response_format="text" \
    -F language="ko" \
    https://api.openai.com/v1/audio/transcriptions)

  if [[ "$http_status" == "200" ]]; then
    cat "$response_tmp"
    rm -f "$response_tmp"
    return 0
  else
    echo "HTTP_ERROR:$http_status" >&2
    rm -f "$response_tmp"
    return 1
  fi
}

transcribe_video() {
  local video_path="$1"
  local out_txt="$2"
  local title="$3"

  if [[ -f "$out_txt" ]]; then
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

  # 전체 오디오 추출
  local audio_full="${tmp_dir}/full.mp3"
  ffmpeg -i "$video_path" -vn -ar 16000 -ac 1 -b:a 32k "$audio_full" -y -loglevel error

  if [[ ! -f "$audio_full" ]]; then
    echo "  [TRANSCRIBE] 실패: 오디오 추출 실패"
    rm -rf "$tmp_dir"
    return 1
  fi

  local size
  size=$(stat -f%z "$audio_full" 2>/dev/null || stat -c%s "$audio_full")
  local max_size=24000000  # 24MB

  local final_text=""

  if [[ $size -le $max_size ]]; then
    # 24MB 이하: 그대로 처리
    echo "  [TRANSCRIBE] 단일 처리 ($(( size / 1024 / 1024 ))MB)"
    final_text=$(call_whisper "$audio_full")
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
      ffmpeg -i "$audio_full" -ss "$offset" -t "$chunk_sec" -c copy "$audio_chunk" -y -loglevel error

      if [[ -f "$audio_chunk" ]]; then
        local chunk_text
        chunk_text=$(call_whisper "$audio_chunk")
        [[ -n "$chunk_text" ]] && final_text="${final_text}${chunk_text}"$'\n'
        rm -f "$audio_chunk"
      fi

      offset=$((offset + chunk_sec))
      chunk_num=$((chunk_num + 1))
    done
  fi

  rm -rf "$tmp_dir"

  if [[ -n "$final_text" ]]; then
    echo "$final_text" > "$out_txt"
    echo "  [TRANSCRIBE] 완료: $out_txt"
  else
    echo "  [TRANSCRIBE] 실패: 결과 없음"
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
    http_status=$(curl -s -o "$json_tmp" -w "%{http_code}" \
      "${module_cookie_args[@]}" \
      -H "Authorization: Bearer ${CANVAS_TOKEN:-}" \
      -H "Referer: https://canvas.ssu.ac.kr/" \
      "$api_url")

    if [[ "$http_status" == "000" ]]; then
      echo "Error: 서버 연결 실패"
      rm -f "$json_tmp"; return 1
    elif [[ "$http_status" == "401" ]]; then
      echo "Error: 인증 실패 — CANVAS_TOKEN 확인"
      rm -f "$json_tmp"; return 1
    elif [[ "$http_status" == "404" ]]; then
      echo "Error: 강의를 찾을 수 없음 — course_id($course_id) 확인"
      rm -f "$json_tmp"; return 1
    elif [[ "$http_status" != "200" ]]; then
      echo "Error: API 요청 실패 (HTTP $http_status)"
      echo "응답: $(head -c 300 "$json_tmp")"
      rm -f "$json_tmp"; return 1
    fi
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
    "${course_cookie_args[@]}" \
    -H "Referer: https://canvas.ssu.ac.kr/" \
    -H "Authorization: Bearer ${CANVAS_TOKEN:-}" \
    "https://canvas.ssu.ac.kr/learningx/api/v1/courses/${course_id}")
  course_name=$(jq -r '.name // ""' "$course_tmp" 2>/dev/null || true)
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

  jq -c '.[]' "$json_tmp" | while read -r module; do
    local week week_title item_count week_dir
    week=$(jq <<< "$module" -r '.week_position')
    week_title=$(jq <<< "$module" -r '.title')

    is_week_included "$week" || continue

    item_count=$(jq <<< "$module" '.module_items | length')
    [[ "$item_count" -eq 0 ]] && continue

    week_dir="${course_dir}/${week_title}"

    echo ""
    echo "────────────────────────────────────────"
    echo " ${week_title}"
    echo "────────────────────────────────────────"

    jq <<< "$module" -c '.module_items[]?' | while read -r item; do
      local content_type opened title inner_type view_url
      content_type=$(jq <<< "$item" -r '.content_type')
      [[ "$content_type" == "wiki_page" ]] && continue

      opened=$(jq <<< "$item" -r '.content_data.opened // false')
      $OPENED_ONLY && [[ "$opened" != "true" ]] && continue

      title=$(jq <<< "$item" -r '.title' | tr '/' '-')
      inner_type=$(jq <<< "$item" -r '.content_data.item_content_data.content_type')
      view_url=$(jq <<< "$item" -r '.content_data.item_content_data.view_url // ""')

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
          [[ -z "$view_url" ]] && echo "  [SKIP] URL 없음 (미공개)" && continue

          local ext fname
          ext="${inner_type}"
          [[ "$inner_type" == "file" ]] && {
            fname=$(jq <<< "$item" -r '.content_data.item_content_data.file_name // ""')
            ext="${fname##*.}"
          }
          download_file "$view_url" "${week_dir}/${title}.${ext}" "$title"
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
  process_course "" "$JSON_FILE"
else
  for course_id in "${COURSE_IDS[@]}"; do
    echo ""
    echo "########################################"
    echo " 강의 처리: $course_id"
    echo "########################################"
    process_course "$course_id" ""
  done
fi

echo ""
echo "========================================"
echo " 전체 완료. 출력: $OUTPUT_DIR"
echo "========================================"
