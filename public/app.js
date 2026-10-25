// ── State ───────────────────────────────────────────────────
const state = {
  selectedCourses: [],   // [{courseId, courseName}]
  semesters: [],
  selectedTermId: null,
  isDownloading: false,
  eventSource: null,
  problems: [],          // failures and attachments that cannot be downloaded, for the current run
  lastNotifyAt: 0,
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
    const res = await fetch('/api/config');
    const config = await res.json();
    $('#openaiApiKey').placeholder = config.hasOpenaiKey ? '(설정됨) 변경하려면 새로 입력' : 'sk-...';
    $('#outputDir').value = config.outputDir || '';
    renderFilePreview();
    $('#transcribeEngine').value = config.transcribeEngine || 'local';
    updateEngineFields();
    $('#whisperUrl').value = config.whisperUrl || '';
    $('#whisperModel').value = config.whisperModel || '';
    if (config.cpuCores) {
      $('#cpuThreads').max = config.cpuCores;
      $('#cpuThreadsMax').textContent = config.cpuCores;
    }
    updateTokenStatus();
  } catch (e) {
    console.error('Config load failed:', e);
  }
}

async function updateTokenStatus() {
  try {
    const res = await fetch('/api/config');
    const config = await res.json();

    // Learningx token status (JWT with expiry)
    const lxEl = $('#learningxTokenStatus');
    if (lxEl) {
      if (!config.hasLearningxToken) {
        lxEl.innerHTML = '<span class="badge badge-warning">&#9888; 미설정 - Canvas에 로그인하거나 쿠키 파일을 업로드하면 자동 추출됩니다</span>';
      } else if (config.learningxTokenExpiry) {
        const expiry = new Date(config.learningxTokenExpiry);
        const now = new Date();
        const diffHours = (expiry - now) / (1000 * 60 * 60);
        if (diffHours < 0) {
          lxEl.innerHTML = '<span class="badge badge-error">&#10006; 만료됨 - 다시 로그인해주세요</span>';
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
  const outputDir = $('#outputDir').value.trim();

  if (openaiKey) data.openaiApiKey = openaiKey;
  data.outputDir = outputDir;
  data.transcribeEngine = $('#transcribeEngine').value;
  data.whisperUrl = $('#whisperUrl').value.trim();
  data.whisperModel = $('#whisperModel').value.trim();

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
      loadConfig();
      checkCookieStatus();
    } else {
      showToast(result.error || '저장 실패', 'error');
    }
  } catch (e) {
    showToast('서버 오류', 'error');
  }
});

// ── Transcription engine ───────────────────────────────────
// 고른 방식에 필요한 입력란만 보여 준다
function updateEngineFields() {
  const engine = $('#transcribeEngine').value;
  $$('.engine-field, .engine-hint').forEach((el) => {
    el.style.display = el.dataset.engine === engine ? '' : 'none';
  });
}
$('#transcribeEngine').addEventListener('change', updateEngineFields);

// ── Output folder picker (desktop app only) ────────────────
// 앱에서는 Finder 폴더 선택 창으로 고르고 바로 저장한다. 브라우저에서는 경로를 직접 입력한다
if (window.lmsApp) {
  $('#outputDir').readOnly = true;
  $('#pickOutputDirBtn').style.display = '';
  $('#pickOutputDirBtn').addEventListener('click', async () => {
    const dir = await window.lmsApp.pickFolder($('#outputDir').value);
    if (!dir) return;
    try {
      const res = await fetch('/api/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ outputDir: dir }),
      });
      if (!res.ok) throw new Error((await res.json()).error || '저장 실패');
      $('#outputDir').value = dir;
      renderFilePreview();
      showToast('출력 폴더를 저장했습니다.');
    } catch (e) {
      showToast(e.message, 'error');
    }
  });
}

// ── Canvas login (desktop app only) ───────────────────────
// The preload script exposes window.lmsApp; a plain browser tab falls back to cookie upload
if (window.lmsApp) {
  $('#loginCard').style.display = 'block';
  $('#canvasLoginBtn').addEventListener('click', async () => {
    const btn = $('#canvasLoginBtn');
    btn.disabled = true;
    try {
      const result = await window.lmsApp.login();
      showToast(result.message, result.ok ? 'success' : 'error');
      checkCookieStatus();
      updateTokenStatus();
      loadTerms();
    } catch (e) {
      showToast(`로그인 실패: ${e.message}`, 'error');
    } finally {
      btn.disabled = false;
    }
  });
}

// ── Required tools (desktop app only) ─────────────────────
async function loadDeps() {
  const tools = await window.lmsApp.depsStatus();
  $('#depsList').innerHTML = tools.map((t) =>
    `<div class="dep-row">
      <span class="dep-name">${escapeHtml(t.name)}</span>
      <span class="dep-purpose">${escapeHtml(t.purpose)}</span>
      <span class="dep-state ${t.path ? 'ok' : 'missing'}">${t.path ? '설치됨' : '없음'}</span>
    </div>`
  ).join('');
  $('#installDepsBtn').style.display = tools.some((t) => !t.path) ? '' : 'none';
}

if (window.lmsApp) {
  $('#depsCard').style.display = 'block';
  loadDeps();
  window.lmsApp.onDepsProgress(({ name, index, total }) => {
    $('#installDepsBtn').textContent = `설치 중: ${name} (${index + 1}/${total})`;
  });
  $('#installDepsBtn').addEventListener('click', async () => {
    const btn = $('#installDepsBtn');
    btn.disabled = true;
    try {
      const result = await window.lmsApp.installDeps();
      showToast(result.message, result.ok ? 'success' : 'error');
    } finally {
      btn.disabled = false;
      btn.innerHTML = '&#11015; 없는 도구 설치';
      loadDeps();
    }
  });
}

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
      updateTokenStatus();
      loadTerms();
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
$('#termSelect').addEventListener('change', loadCourses);

async function loadTerms() {
  const select = $('#termSelect');
  try {
    const res = await fetch('/api/canvas/terms');
    const data = await res.json();
    if (!res.ok) throw new Error(data.error || 'API 오류');
    select.innerHTML = data.map((t) => `<option value="${t.id}">${escapeHtml(t.name)}</option>`).join('');
  } catch {
    // 로그인 전에는 목록이 없으므로 최근 학기로 불러오게 둔다
    select.innerHTML = '<option value="">최근 학기</option>';
  }
}

async function loadCourses() {
  const courseList = $('#courseList');
  courseList.innerHTML = '<div class="loading"><div class="spinner"></div> 강의 불러오는 중...</div>';
  // 목록을 새로 그리면 이전에 고른 강의 체크박스가 사라지므로 선택도 비운다
  updateSelectedCourses();
  $('#selectAllBtn').textContent = '전체 선택';

  try {
    const termId = $('#termSelect').value;
    const res = await fetch(termId ? `/api/canvas/courses?termId=${termId}` : '/api/canvas/courses');
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
  renderFilePreview();
  el.innerHTML = state.selectedCourses.map((c) =>
    `<div style="display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid var(--border-light);font-size:14px;">
      <div style="flex:1;min-width:0;">
        <strong>${escapeHtml(c.courseName)}</strong>
        <span style="color:var(--text-muted);font-size:12px;margin-left:8px;">ID: ${c.courseId}</span>
      </div>
      <input type="text" class="form-input week-filter-input" data-course-id="${c.courseId}"
        placeholder="전체" style="width:100px;padding:4px 8px;font-size:12px;text-align:center;"
        title="주차 필터 (예: 1,2,3)">
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

  // The app asks before installing any missing tool; stop if the user declines
  if (window.lmsApp) {
    const result = await window.lmsApp.ensureDeps();
    loadDeps();
    if (!result.ok) {
      showToast(result.message, 'error');
      return;
    }
  }

  state.isDownloading = true;
  $('#startBtn').style.display = 'none';
  $('#stopBtn').style.display = 'inline-flex';
  $('#progressPanel').classList.add('active');
  $('#progressSpinner').style.display = 'block';
  $('#progressLabel').textContent = '다운로드 준비 중...';
  $('#progressCounter').textContent = '';

  resetProblems();

  // Build per-course progress panels
  const progressList = $('#courseProgressList');
  progressList.innerHTML = '';
  state.courseProgressData = {};

  state.selectedCourses.forEach((c) => {
    const weekInput = document.querySelector(`.week-filter-input[data-course-id="${c.courseId}"]`);
    const weekLabel = weekInput && weekInput.value.trim() ? `${weekInput.value.trim()}주차` : '전체';

    state.courseProgressData[c.courseId] = { status: 'waiting', logCount: 0 };

    const card = document.createElement('div');
    card.className = 'course-progress-card';
    card.id = `progress-${c.courseId}`;
    card.innerHTML = `
      <div class="course-progress-header" onclick="toggleCourseLog('${c.courseId}')">
        <div class="course-progress-info">
          <span class="course-progress-name">${escapeHtml(c.courseName)}</span>
          <span class="course-progress-status" id="status-text-${c.courseId}">${weekLabel} - 대기 중</span>
        </div>
        <span class="course-progress-badge waiting" id="badge-${c.courseId}">대기</span>
      </div>
      <div class="course-progress-bar"><div class="course-progress-bar-fill" id="bar-${c.courseId}" style="width:0%"></div></div>
      <div class="course-progress-body" id="body-${c.courseId}">
        <div class="course-log-container" id="log-${c.courseId}"></div>
      </div>
    `;
    progressList.appendChild(card);
  });

  // Collect per-course week filters
  const courseWeeks = {};
  state.selectedCourses.forEach((c) => {
    const input = document.querySelector(`.week-filter-input[data-course-id="${c.courseId}"]`);
    const weeks = input ? input.value.trim() : '';
    courseWeeks[c.courseId] = weeks;
  });

  const params = new URLSearchParams();
  params.set('courseWeeks', JSON.stringify(courseWeeks));
  params.set('doVideo', $('#optVideo').checked);
  params.set('doFile', $('#optFile').checked);
  params.set('doAttach', $('#optAttach').checked);
  params.set('doSrt', $('#optSrt').checked);
  params.set('doTranscribe', $('#optTranscribe').checked);
  params.set('doCompress', $('#optCompress').checked);
  params.set('compressSize', $('#compressSize').value);
  params.set('openedOnly', $('#optOpenedOnly').checked);
  params.set('cpuThreads', $('#cpuThreads').value);

  const eventSource = new EventSource(`/api/download/start?${params.toString()}`);
  state.eventSource = eventSource;

  let completedCount = 0;
  const totalCourses = state.selectedCourses.length;

  eventSource.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      const cid = msg.courseId;

      if (msg.type === 'course_start' && cid) {
        updateCoursePanel(cid, 'running', msg.data);
        $('#progressLabel').textContent = `다운로드 중... (${completedCount}/${totalCourses})`;
      } else if (msg.type === 'course_done' && cid) {
        completedCount++;
        updateCoursePanel(cid, msg.ok ? 'done' : 'error', msg.data);
        $('#progressCounter').textContent = `${completedCount}/${totalCourses}`;
        $('#progressLabel').textContent = `다운로드 중... (${completedCount}/${totalCourses})`;
      } else if (msg.type === 'complete' || msg.type === 'cancelled') {
        finishDownload(msg.type);
      } else if (cid) {
        appendCourseLog(cid, msg.type === 'fail' ? 'fail' : msg.type, msg.type === 'fail' ? `실패: ${msg.data}` : msg.data);
        if (msg.type === 'download' || msg.type === 'transcribe') {
          updateCourseStatusText(cid, msg.data);
        }
        if (msg.type === 'fail') {
          addProblem(cid, msg.data, 'fail');
        } else if (msg.type === 'error' || (msg.type === 'warning' && msg.data.includes('받을 수 없음'))) {
          addProblem(cid, msg.data, msg.type);
        }
      }
    } catch {
      // ignore parse errors
    }
  };

  eventSource.onerror = () => {
    if (state.isDownloading) {
      finishDownload('error');
      showToast('서버와의 연결이 끊어졌습니다.', 'error');
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

  const failed = state.problems.filter((p) => p.level === 'fail' || p.level === 'error').length;
  if (finalType === 'complete' && failed > 0) {
    $('#progressLabel').textContent = `완료, 실패 ${failed}건`;
    showToast(`다운로드를 마쳤지만 ${failed}건이 실패했습니다. 아래 목록에서 원인을 확인해 주세요.`, 'error');
    notify('다운로드 완료 (실패 있음)', `${failed}건을 받지 못했습니다. 앱에서 원인을 확인해 주세요.`);
    $('#problemCard').scrollIntoView({ behavior: 'smooth', block: 'start' });
  } else if (finalType === 'complete') {
    $('#progressLabel').textContent = '완료!';
    showToast('다운로드가 완료되었습니다.');
    notify('다운로드 완료', '선택한 강의를 모두 받았습니다.');
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
}

// ── Problems ────────────────────────────────────────────────
const PROBLEM_KINDS = {
  video: '영상', file: '자료', transcribe: '음성 인식', compress: '압축',
  link: '링크', attach: '첨부', course: '강의', json: '강의',
};

function resetProblems() {
  state.problems = [];
  state.lastNotifyAt = 0;
  $('#problemList').innerHTML = '';
  $('#problemCard').style.display = 'none';
}

// fail lines look like "video: 1강 개요 :: 응답 시간 초과: ..."
function parseProblem(text, level) {
  if (level === 'fail') {
    const [head, ...rest] = text.split(' :: ');
    const m = head.match(/^(\w+):\s*(.*)$/);
    return {
      kind: m ? (PROBLEM_KINDS[m[1]] || m[1]) : '오류',
      item: m ? m[2] : head,
      reason: rest.join(' :: ') || '원인을 알 수 없음',
    };
  }
  if (level === 'warning') {
    const body = text.replace(/^\[SKIP\]\s*첨부를 받을 수 없음:\s*/, '');
    const [item, ...rest] = body.split(' :: ');
    return { kind: '첨부', item, reason: rest.join(' :: ') || body };
  }
  return { kind: '오류', item: '', reason: text.replace(/^Error:\s*/, '') };
}

function addProblem(courseId, text, level) {
  const p = { courseId, level, ...parseProblem(text, level) };
  state.problems.push(p);
  const course = state.selectedCourses.find((c) => c.courseId === courseId);
  const row = document.createElement('div');
  row.className = 'problem-row';
  row.innerHTML = `
    <div class="problem-head">
      <span class="problem-kind ${level === 'warning' ? 'warn' : ''}">${escapeHtml(p.kind)}</span>
      <span class="problem-item">${escapeHtml(p.item)}</span>
      <span class="problem-course">${escapeHtml(course ? course.courseName : courseId)}</span>
    </div>
    <div class="problem-reason">${escapeHtml(p.reason)}</div>`;
  $('#problemList').appendChild(row);
  $('#problemCard').style.display = 'block';
  const failed = state.problems.filter((x) => x.level !== 'warning').length;
  const warned = state.problems.length - failed;
  $('#problemCount').textContent = [failed && `실패 ${failed}`, warned && `받을 수 없음 ${warned}`].filter(Boolean).join(' · ');

  if (level !== 'warning') {
    showToast(`${p.kind} 실패: ${p.item}`, 'error');
    // Downloads run for a long time in the background; tell the user without flooding them
    if (Date.now() - state.lastNotifyAt > 30000) {
      state.lastNotifyAt = Date.now();
      notify(`${p.kind} 실패: ${p.item}`, p.reason);
    }
  }
}

function notify(title, body) {
  try {
    if (!('Notification' in window)) return;
    if (Notification.permission === 'granted') {
      new Notification(title, { body });
    } else if (Notification.permission !== 'denied') {
      Notification.requestPermission().then((perm) => {
        if (perm === 'granted') new Notification(title, { body });
      });
    }
  } catch {
    // notifications are a convenience only
  }
}

if (window.lmsApp) {
  $('#openLogsBtn').style.display = '';
  $('#openLogsBtn').addEventListener('click', () => window.lmsApp.openLogs());
}

function appendCourseLog(courseId, type, text) {
  const container = $(`#log-${courseId}`);
  if (!container) return;
  const line = document.createElement('div');
  line.className = `log-line type-${type}`;
  line.textContent = text;
  container.appendChild(line);
  container.scrollTop = container.scrollHeight;
}

function updateCoursePanel(courseId, status, text) {
  const card = $(`#progress-${courseId}`);
  const badge = $(`#badge-${courseId}`);
  const bar = $(`#bar-${courseId}`);
  if (!card) return;

  card.className = `course-progress-card status-${status}`;

  if (status === 'running') {
    badge.className = 'course-progress-badge running';
    badge.innerHTML = '<span class="mini-spinner"></span> 진행 중';
    bar.style.width = '30%';
    updateCourseStatusText(courseId, text + ' - 다운로드 중');
    // Auto-expand running course log
    const body = $(`#body-${courseId}`);
    if (body) body.classList.add('expanded');
  } else if (status === 'done') {
    badge.className = 'course-progress-badge done';
    badge.textContent = '완료';
    bar.style.width = '100%';
    bar.classList.add('done');
    updateCourseStatusText(courseId, '완료');
  } else if (status === 'error') {
    badge.className = 'course-progress-badge error';
    badge.textContent = '오류';
    bar.style.width = '100%';
    updateCourseStatusText(courseId, text);
  }
}

function updateCourseStatusText(courseId, text) {
  const el = $(`#status-text-${courseId}`);
  if (el) {
    // Truncate long status text
    el.textContent = text.length > 60 ? text.substring(0, 57) + '...' : text;
  }
}

function toggleCourseLog(courseId) {
  const body = $(`#body-${courseId}`);
  if (body) body.classList.toggle('expanded');
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

// ── Compress options toggle ─────────────────────────────────
$('#optCompress').addEventListener('change', () => {
  $('#compressOptions').style.display = $('#optCompress').checked ? 'block' : 'none';
});

$('#compressSize').addEventListener('input', () => {
  $('#compressSizeLabel').textContent = `${$('#compressSize').value}MB`;
  renderFilePreview();
});

// ── File preview ────────────────────────────────────────────
// Mirrors the folder layout lms_download.sh writes, so users can see what each option produces
function renderFilePreview() {
  const video = $('#optVideo').checked;
  const file = $('#optFile').checked;
  const attach = $('#optAttach').checked;
  const transcribe = $('#optTranscribe').checked;
  const srt = transcribe && $('#optSrt').checked;
  const compress = video && $('#optCompress').checked;

  // Subtitles come from speech recognition, and compression needs a saved video
  $('#optSrt').disabled = !transcribe;
  $('#optSrt').closest('.option-item').classList.toggle('disabled', !transcribe);
  $('#optCompress').disabled = !video;
  $('#optCompress').closest('.option-item').classList.toggle('disabled', !video);

  const lecture = '1강 운영체제 개요';
  const weekFiles = [];
  if (video) {
    weekFiles.push(['&#127909;', `${lecture}.mp4`, compress ? `강의 영상 (${$('#compressSize').value}MB 이하로 압축)` : '강의 영상']);
  }
  if (transcribe) weekFiles.push(['&#128221;', `${lecture}.txt`, '음성 인식 텍스트']);
  if (srt) weekFiles.push(['&#128172;', `${lecture}.srt`, '시간이 붙은 자막 (영상 플레이어에서 사용)']);
  if (file) {
    weekFiles.push(['&#128196;', '강의자료.pdf', 'PPT, HWP 등 올라온 원본 그대로']);
    weekFiles.push(['&#128279;', '참고 링크.webloc', '외부 링크 (더블클릭하면 열림)']);
  }

  const kinds = [];
  if (video) kinds.push('mp4 영상');
  if (transcribe) kinds.push('txt 텍스트');
  if (srt) kinds.push('srt 자막');
  if (file) kinds.push('강의자료 원본', 'webloc 링크');
  if (attach) kinds.push('공지·과제 첨부');
  $('#fileKinds').innerHTML = kinds.map((k) => `<span class="file-kind">${k}</span>`).join('');

  const courseName = state.selectedCourses[0]?.courseName || '강의 이름';
  const rows = [[0, '&#128193;', `${$('#outputDir').value || '출력 폴더'}/`, '']];
  rows.push([1, '&#128193;', `${courseName}/`, '']);
  if (weekFiles.length) {
    rows.push([2, '&#128193;', '1주차/', '주차마다 폴더가 생깁니다']);
    weekFiles.forEach(([icon, name, desc]) => rows.push([3, icon, name, desc]));
  }
  if (attach) {
    rows.push([2, '&#128193;', '공지/공지 제목/', '']);
    rows.push([3, '&#128206;', '첨부파일.hwp', '공지에 올라온 첨부']);
    rows.push([2, '&#128193;', '과제/과제 제목/', '']);
    rows.push([3, '&#128206;', '첨부파일.pdf', '과제에 올라온 첨부']);
  }

  if (rows.length === 2) {
    $('#fileTree').innerHTML = '<div class="tree-empty">선택한 옵션으로는 저장되는 파일이 없습니다. 위에서 하나 이상 체크해 주세요.</div>';
  } else {
    $('#fileTree').innerHTML = rows.map(([depth, icon, name, desc]) =>
      `<div class="tree-row" style="padding-left:${depth * 20}px">
        <span>${icon}</span><span class="tree-name">${escapeHtml(name)}</span>
        ${desc ? `<span class="tree-desc">${desc}</span>` : ''}
      </div>`
    ).join('');
  }

  const notes = [];
  if (!video && transcribe) notes.push(`영상은 음성 인식에만 쓰고 저장하지 않습니다. ${srt ? '텍스트와 자막만' : '텍스트만'} 남습니다.`);
  if (transcribe && !srt) notes.push('자막 파일(.srt)도 필요하면 "자막(srt) 저장"을 체크하세요.');
  if (transcribe) notes.push('이미 만들어진 텍스트와 자막은 다시 만들지 않습니다.');
  $('#fileNotes').innerHTML = notes.map((n) => `<p>&#8226; ${n}</p>`).join('');
}

['#optVideo', '#optFile', '#optAttach', '#optTranscribe', '#optSrt', '#optCompress'].forEach((id) => {
  $(id).addEventListener('change', renderFilePreview);
});

$('#cpuThreads').addEventListener('input', () => {
  const val = parseInt($('#cpuThreads').value);
  $('#cpuThreadsLabel').textContent = val === 0 ? '자동' : `${val} 스레드`;
});

// ── Init ────────────────────────────────────────────────────
loadConfig();
loadTerms();
checkCookieStatus();
updateSelectedSummary();
renderFilePreview();
