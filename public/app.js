// ── State ───────────────────────────────────────────────────
const state = {
  selectedCourses: [],   // [{courseId, courseName}]
  semesters: [],
  selectedTermId: null,
  isDownloading: false,
  eventSource: null,
};

// ── DOM refs ────────────────────────────────────────────────
const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => document.querySelectorAll(sel);

// ── Theme ───────────────────────────────────────────────────
function initTheme() {
  const saved = localStorage.getItem('theme');
  if (saved === 'dark' || (!saved && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
    document.documentElement.setAttribute('data-theme', 'dark');
  }
}

$('#themeToggle').addEventListener('click', () => {
  const isDark = document.documentElement.getAttribute('data-theme') === 'dark';
  document.documentElement.setAttribute('data-theme', isDark ? 'light' : 'dark');
  localStorage.setItem('theme', isDark ? 'light' : 'dark');
  $('#themeToggle').innerHTML = isDark ? '&#9790;' : '&#9788;';
});

initTheme();
if (document.documentElement.getAttribute('data-theme') === 'dark') {
  $('#themeToggle').innerHTML = '&#9788;';
}

// ── Tabs ────────────────────────────────────────────────────
$$('.tab-btn').forEach((btn) => {
  btn.addEventListener('click', () => {
    $$('.tab-btn').forEach((b) => b.classList.remove('active'));
    $$('.tab-content').forEach((c) => c.classList.remove('active'));
    btn.classList.add('active');
    $(`#tab-${btn.dataset.tab}`).classList.add('active');
  });
});

// ── Toast ───────────────────────────────────────────────────
function showToast(message, type = 'success') {
  const container = $('#toastContainer');
  const toast = document.createElement('div');
  toast.className = `toast toast-${type}`;
  toast.textContent = message;
  container.appendChild(toast);
  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateX(30px)';
    toast.style.transition = '0.3s ease';
    setTimeout(() => toast.remove(), 300);
  }, 3000);
}

// ── Settings ────────────────────────────────────────────────
async function loadConfig() {
  try {
    const res = await fetch('/api/config/raw');
    const config = await res.json();
    $('#openaiApiKey').placeholder = config.openaiApiKey ? '(설정됨) 변경하려면 새로 입력' : 'sk-...';
    $('#canvasToken').placeholder = config.standardToken ? '(설정됨) 변경하려면 새로 입력' : '64자리 액세스 토큰 입력';
    $('#outputDir').value = config.outputDir || '';
    $('#scriptPath').value = config.scriptPath || '';
    updateTokenStatus();
  } catch (e) {
    console.error('Config load failed:', e);
  }
}

async function updateTokenStatus() {
  try {
    const res = await fetch('/api/config');
    const config = await res.json();

    // Standard token status
    const stdEl = $('#standardTokenStatus');
    if (stdEl) {
      if (!config.hasStandardToken) {
        stdEl.innerHTML = '<span class="badge badge-warning">&#9888; 미설정 - 강의 목록을 불러오려면 입력 필요</span>';
      } else {
        stdEl.innerHTML = '<span class="badge badge-success">&#10004; 설정됨</span>';
      }
    }

    // Learningx token status (JWT with expiry)
    const lxEl = $('#learningxTokenStatus');
    if (lxEl) {
      if (!config.hasLearningxToken) {
        lxEl.innerHTML = '<span class="badge badge-warning">&#9888; 미설정 - 쿠키 파일을 업로드하면 자동 추출됩니다</span>';
      } else if (config.learningxTokenExpiry) {
        const expiry = new Date(config.learningxTokenExpiry);
        const now = new Date();
        const diffHours = (expiry - now) / (1000 * 60 * 60);
        if (diffHours < 0) {
          lxEl.innerHTML = '<span class="badge badge-error">&#10006; 만료됨 - 쿠키를 다시 업로드해주세요</span>';
        } else if (diffHours < 24) {
          lxEl.innerHTML = `<span class="badge badge-warning">&#9888; ${Math.floor(diffHours)}시간 후 만료</span>`;
        } else {
          const diffDays = Math.floor(diffHours / 24);
          lxEl.innerHTML = `<span class="badge badge-success">&#10004; 유효 (${diffDays}일 남음)</span>`;
        }
      } else {
        lxEl.innerHTML = '<span class="badge badge-success">&#10004; 설정됨</span>';
      }
    }
  } catch {
    // ignore
  }
}

$('#saveConfigBtn').addEventListener('click', async () => {
  const data = {};
  const openaiKey = $('#openaiApiKey').value.trim();
  const canvasToken = $('#canvasToken').value.trim();
  const outputDir = $('#outputDir').value.trim();
  const scriptPath = $('#scriptPath').value.trim();

  if (openaiKey) data.openaiApiKey = openaiKey;
  if (canvasToken) data.canvasToken = canvasToken;
  data.outputDir = outputDir;
  data.scriptPath = scriptPath;

  try {
    const res = await fetch('/api/config', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
    const result = await res.json();

    if (res.ok) {
      showToast('설정이 저장되었습니다.');
      $('#openaiApiKey').value = '';
      $('#canvasToken').value = '';
      loadConfig();
      checkCookieStatus();
    } else {
      showToast(result.error || '저장 실패', 'error');
    }
  } catch (e) {
    showToast('서버 오류', 'error');
  }
});

// ── Cookie upload ──────────────────────────────────────────
$('#cookieUploadBtn').addEventListener('click', () => $('#cookieFileInput').click());

$('#cookieFileInput').addEventListener('change', (e) => {
  if (e.target.files[0]) uploadCookieFile(e.target.files[0]);
});

// Drag & drop
const uploadArea = $('#cookieUploadArea');
uploadArea.addEventListener('dragover', (e) => {
  e.preventDefault();
  uploadArea.classList.add('drag-over');
});
uploadArea.addEventListener('dragleave', () => uploadArea.classList.remove('drag-over'));
uploadArea.addEventListener('drop', (e) => {
  e.preventDefault();
  uploadArea.classList.remove('drag-over');
  if (e.dataTransfer.files[0]) uploadCookieFile(e.dataTransfer.files[0]);
});

async function uploadCookieFile(file) {
  const text = await file.text();
  try {
    const res = await fetch('/api/config/upload-cookie', {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: text,
    });
    const data = await res.json();
    if (res.ok) {
      showToast(data.message);
      checkCookieStatus();
    } else {
      showToast(data.error || '업로드 실패', 'error');
    }
  } catch {
    showToast('서버 오류', 'error');
  }
}

// ── Cookie status check ────────────────────────────────────
async function checkCookieStatus() {
  const el = $('#cookieStatus');
  try {
    const res = await fetch('/api/config/check-cookie');
    const data = await res.json();
    if (data.valid) {
      el.innerHTML = '<span class="badge badge-success">&#10004; ' + data.message + '</span>';
    } else {
      el.innerHTML = '<span class="badge badge-error">&#10006; ' + data.message + '</span>';
    }
  } catch {
    el.innerHTML = '';
  }
}

// ── Courses ─────────────────────────────────────────────────
$('#loadCoursesBtn').addEventListener('click', loadCourses);

async function loadCourses() {
  const courseList = $('#courseList');
  courseList.innerHTML = '<div class="loading"><div class="spinner"></div> 강의 불러오는 중...</div>';

  try {
    const res = await fetch('/api/canvas/courses');
    if (!res.ok) {
      const err = await res.json();
      throw new Error(err.error || 'API 오류');
    }
    const courses = await res.json();

    if (courses.length === 0) {
      courseList.innerHTML = '<div class="empty-state"><p>등록된 강의가 없습니다.</p></div>';
      return;
    }

    courseList.innerHTML = '';
    courses.forEach((course) => {
      const formatBadge = course.courseFormat ? `<span class="badge badge-info">${course.courseFormat}</span>` : '';
      const div = document.createElement('div');
      div.className = 'course-item';
      div.dataset.courseId = course.courseId;
      div.innerHTML = `
        <input type="checkbox" class="course-checkbox" data-course-id="${course.courseId}" data-course-name="${escapeAttr(course.courseName)}">
        <div class="course-info">
          <div class="course-name">${escapeHtml(course.courseName)}</div>
          <div class="course-meta">ID: ${course.courseId} ${formatBadge}</div>
        </div>
      `;
      div.addEventListener('click', (e) => {
        if (e.target.tagName === 'INPUT') return;
        const cb = div.querySelector('.course-checkbox');
        cb.checked = !cb.checked;
        cb.dispatchEvent(new Event('change'));
      });
      const cb = div.querySelector('.course-checkbox');
      cb.addEventListener('change', () => {
        div.classList.toggle('selected', cb.checked);
        updateSelectedCourses();
      });
      courseList.appendChild(div);
    });
  } catch (e) {
    courseList.innerHTML = `<div class="empty-state"><p style="color:var(--error)">오류: ${e.message}</p></div>`;
  }
}

$('#selectAllBtn').addEventListener('click', () => {
  const checkboxes = $$('.course-checkbox');
  const allChecked = Array.from(checkboxes).every((cb) => cb.checked);

  checkboxes.forEach((cb) => {
    cb.checked = !allChecked;
    cb.closest('.course-item').classList.toggle('selected', cb.checked);
  });
  updateSelectedCourses();
  $('#selectAllBtn').textContent = allChecked ? '전체 선택' : '전체 해제';
});

function updateSelectedCourses() {
  const checked = $$('.course-checkbox:checked');
  state.selectedCourses = Array.from(checked).map((cb) => ({
    courseId: cb.dataset.courseId,
    courseName: cb.dataset.courseName,
  }));
  updateSelectedSummary();
}

function updateSelectedSummary() {
  const el = $('#selectedCoursesList');
  const startBtn = $('#startBtn');

  if (state.selectedCourses.length === 0) {
    el.innerHTML = '<div class="empty-state"><p>강의 선택 탭에서 강의를 먼저 선택해주세요</p></div>';
    startBtn.disabled = true;
    return;
  }

  startBtn.disabled = false;
  el.innerHTML = state.selectedCourses.map((c) =>
    `<div style="padding:6px 0;border-bottom:1px solid var(--border-light);font-size:14px;">
      <strong>${escapeHtml(c.courseName)}</strong>
      <span style="color:var(--text-muted);font-size:12px;margin-left:8px;">ID: ${c.courseId}</span>
    </div>`
  ).join('');
}

// ── Download ────────────────────────────────────────────────
$('#startBtn').addEventListener('click', startDownload);
$('#stopBtn').addEventListener('click', stopDownload);

async function startDownload() {
  if (state.selectedCourses.length === 0) {
    showToast('강의를 선택해주세요.', 'error');
    return;
  }

  // 쿠키 파일 체크
  try {
    const cookieRes = await fetch('/api/config/check-cookie');
    const cookieData = await cookieRes.json();
    if (!cookieData.valid) {
      showToast('쿠키 파일이 필요합니다. 설정 탭에서 쿠키 파일을 설정해주세요.', 'error');
      return;
    }
  } catch {
    showToast('쿠키 상태 확인 실패', 'error');
    return;
  }

  state.isDownloading = true;
  $('#startBtn').style.display = 'none';
  $('#stopBtn').style.display = 'inline-flex';
  $('#progressPanel').classList.add('active');
  $('#progressSpinner').style.display = 'block';
  $('#progressLabel').textContent = '다운로드 준비 중...';
  $('#logContainer').innerHTML = '';
  appendLog('info', '영상 크기에 따라 다운로드에 시간이 걸릴 수 있습니다. 잠시 기다려주세요.');

  const params = new URLSearchParams();
  params.set('courseIds', state.selectedCourses.map((c) => c.courseId).join(','));
  params.set('doVideo', $('#optVideo').checked);
  params.set('doFile', $('#optFile').checked);
  params.set('doTranscribe', $('#optTranscribe').checked);
  params.set('openedOnly', $('#optOpenedOnly').checked);

  const weekFilter = $('#weekFilter').value.trim();
  if (weekFilter) params.set('weekFilter', weekFilter);

  const eventSource = new EventSource(`/api/download/start?${params.toString()}`);
  state.eventSource = eventSource;

  eventSource.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      appendLog(msg.type, msg.data);

      if (msg.type === 'download' || msg.type === 'transcribe' || msg.type === 'status') {
        $('#progressLabel').textContent = msg.data;
      }

      if (msg.type === 'complete' || msg.type === 'error' || msg.type === 'cancelled') {
        finishDownload(msg.type);
      }
    } catch {
      // ignore parse errors
    }
  };

  eventSource.onerror = () => {
    if (state.isDownloading) {
      finishDownload('error');
      appendLog('error', '서버와의 연결이 끊어졌습니다.');
    }
  };
}

function finishDownload(finalType) {
  state.isDownloading = false;
  if (state.eventSource) {
    state.eventSource.close();
    state.eventSource = null;
  }
  $('#startBtn').style.display = 'inline-flex';
  $('#stopBtn').style.display = 'none';
  $('#progressSpinner').style.display = 'none';

  if (finalType === 'complete') {
    $('#progressLabel').textContent = '완료!';
    showToast('다운로드가 완료되었습니다.');
  } else if (finalType === 'cancelled') {
    $('#progressLabel').textContent = '취소됨';
    showToast('다운로드가 취소되었습니다.', 'error');
  } else {
    $('#progressLabel').textContent = '오류 발생';
  }
}

async function stopDownload() {
  try {
    await fetch('/api/download/stop', { method: 'POST' });
  } catch {
    // ignore
  }
  if (state.eventSource) {
    state.eventSource.close();
    state.eventSource = null;
  }
  finishDownload('cancelled');
  appendLog('cancelled', '사용자에 의해 중지되었습니다.');
}

function appendLog(type, text) {
  const container = $('#logContainer');
  const line = document.createElement('div');
  line.className = `log-line type-${type}`;
  line.textContent = text;
  container.appendChild(line);
  container.scrollTop = container.scrollHeight;
}

// ── Helpers ─────────────────────────────────────────────────
function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

function escapeAttr(str) {
  return str.replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// ── Init ────────────────────────────────────────────────────
loadConfig();
checkCookieStatus();
updateSelectedSummary();
