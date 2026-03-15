const express = require('express');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

const app = express();
const PORT = 8080;

const CONFIG_PATH = path.join(__dirname, 'config.json');
const DEFAULT_SCRIPT_PATH = path.join(__dirname, 'lms_download.sh');

app.use(express.json());
app.use(express.text({ type: 'text/plain', limit: '5mb' }));
app.use(express.static(path.join(__dirname, 'public')));

// ── Config helpers ─────────────────────────────────────────
function loadConfig() {
  try {
    if (fs.existsSync(CONFIG_PATH)) {
      const cfg = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
      // Migrate legacy canvasToken: if it looks like a JWT (contains dots) move it to learningxToken
      if (cfg.canvasToken && !cfg.standardToken && !cfg.learningxToken) {
        if (cfg.canvasToken.includes('.')) {
          cfg.learningxToken = cfg.canvasToken;
        } else {
          cfg.standardToken = cfg.canvasToken;
        }
        delete cfg.canvasToken;
      }
      return { ...defaults, ...cfg };
    }
  } catch (e) {
    console.error('Config load error:', e.message);
  }
  return defaults;
}

const defaults = {
  openaiApiKey: '',
  standardToken: '',
  learningxToken: '',
  cookiesFile: '',
  outputDir: path.join(__dirname, 'output'),
  scriptPath: DEFAULT_SCRIPT_PATH,
};

function saveConfig(config) {
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
}

// ── JWT helpers ────────────────────────────────────────────
function decodeJwtPayload(token) {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) return null;
    let payload = parts[1].replace(/-/g, '+').replace(/_/g, '/');
    while (payload.length % 4) payload += '=';
    return JSON.parse(Buffer.from(payload, 'base64').toString('utf8'));
  } catch {
    return null;
  }
}

function getJwtExpiry(token) {
  const payload = decodeJwtPayload(token);
  if (!payload || !payload.exp) return null;
  return new Date(payload.exp * 1000);
}

function getUserIdFromToken(token) {
  const payload = decodeJwtPayload(token);
  if (!payload) return null;
  return payload.user_login || null;
}

// ── Canvas API proxy ───────────────────────────────────────
function canvasApiRequest(urlPath, token, cookiesFile) {
  return new Promise((resolve, reject) => {
    const fullUrl = new URL(urlPath, 'https://canvas.ssu.ac.kr');
    const options = {
      hostname: fullUrl.hostname,
      path: fullUrl.pathname + fullUrl.search,
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${token}`,
        'Referer': 'https://canvas.ssu.ac.kr/',
      },
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', (chunk) => data += chunk);
      res.on('end', () => {
        if (res.statusCode === 200) {
          try {
            resolve(JSON.parse(data));
          } catch {
            reject(new Error('Invalid JSON response'));
          }
        } else {
          reject(new Error(`API error: HTTP ${res.statusCode}`));
        }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

// ── API Routes ─────────────────────────────────────────────

// Settings
app.get('/api/config', (req, res) => {
  const config = loadConfig();
  // Mask sensitive fields for display; expose non-secret paths as-is
  res.json({
    outputDir: config.outputDir,
    scriptPath: config.scriptPath,
    openaiApiKey: config.openaiApiKey ? '••••••' + config.openaiApiKey.slice(-4) : '',
    standardToken: config.standardToken ? '••••••' + config.standardToken.slice(-8) : '',
    learningxToken: config.learningxToken ? '••••••' + config.learningxToken.slice(-8) : '',
    learningxTokenExpiry: config.learningxToken ? getJwtExpiry(config.learningxToken) : null,
    hasOpenaiKey: !!config.openaiApiKey,
    hasStandardToken: !!config.standardToken,
    hasLearningxToken: !!config.learningxToken,
    cpuCores: require('os').cpus().length,
  });
});

app.post('/api/config', (req, res) => {
  const current = loadConfig();
  const updated = { ...current };

  if (req.body.openaiApiKey !== undefined && req.body.openaiApiKey !== '') {
    updated.openaiApiKey = req.body.openaiApiKey;
  }
  // canvasToken from frontend is the standard /api/v1/ access token (64-char plain token)
  if (req.body.canvasToken !== undefined && req.body.canvasToken !== '') {
    updated.standardToken = req.body.canvasToken;
  }
  if (req.body.cookiesFile !== undefined) updated.cookiesFile = req.body.cookiesFile;
  if (req.body.outputDir !== undefined) updated.outputDir = req.body.outputDir;
  if (req.body.scriptPath !== undefined) updated.scriptPath = req.body.scriptPath;

  saveConfig(updated);
  res.json({ success: true });
});

// Extract xn_api_token from cookie file
function extractXnToken(cookieContent) {
  const lines = cookieContent.split('\n');
  for (const line of lines) {
    if (line.includes('xn_api_token')) {
      const parts = line.split('\t');
      if (parts.length >= 7) return parts[6].trim();
    }
  }
  return null;
}

// Cookie file upload
app.post('/api/config/upload-cookie', (req, res) => {
  try {
    const content = req.body;
    if (!content || typeof content !== 'string') {
      return res.status(400).json({ error: '파일 내용이 비어있습니다.' });
    }
    if (!content.includes('ssu.ac.kr')) {
      return res.status(400).json({ error: '쿠키 파일에 ssu.ac.kr 쿠키가 없습니다. canvas.ssu.ac.kr에서 추출한 파일인지 확인해주세요.' });
    }
    const cookiePath = path.join(__dirname, 'cookies.txt');
    fs.writeFileSync(cookiePath, content);

    // Auto-extract xn_api_token as learningxToken (does NOT overwrite standardToken)
    const xnToken = extractXnToken(content);
    const config = loadConfig();
    config.cookiesFile = cookiePath;
    if (xnToken) {
      config.learningxToken = xnToken;
    }
    saveConfig(config);

    const msg = xnToken
      ? '쿠키 파일 업로드 + Learningx 토큰 자동 추출 완료'
      : '쿠키 파일 업로드 완료 (xn_api_token 없음)';
    res.json({ success: true, path: cookiePath, tokenExtracted: !!xnToken, message: msg });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Cookie file check
app.get('/api/config/check-cookie', (req, res) => {
  const config = loadConfig();
  if (!config.cookiesFile) {
    return res.json({ valid: false, message: '쿠키 파일 경로가 설정되지 않았습니다.' });
  }
  if (!fs.existsSync(config.cookiesFile)) {
    return res.json({ valid: false, message: `파일을 찾을 수 없습니다: ${config.cookiesFile}` });
  }
  const content = fs.readFileSync(config.cookiesFile, 'utf8');
  if (!content.includes('ssu.ac.kr')) {
    return res.json({ valid: false, message: '쿠키 파일에 ssu.ac.kr 쿠키가 없습니다.' });
  }
  return res.json({ valid: true, message: '쿠키 파일 확인 완료' });
});

// Canvas API proxy: 강의 목록 (learningx API 사용)
app.get('/api/canvas/courses', async (req, res) => {
  try {
    const config = loadConfig();
    const token = config.learningxToken;
    if (!token) return res.status(400).json({ error: '쿠키 파일을 먼저 업로드해주세요. (Learningx 토큰이 자동 추출됩니다)' });

    // 1. JWT에서 user_login 추출
    const userId = getUserIdFromToken(token);
    if (!userId) return res.status(400).json({ error: '토큰에서 사용자 ID를 추출할 수 없습니다.' });

    // 2. 학기 목록 가져오기
    const termsData = await canvasApiRequest(
      `/learningx/api/v1/users/${userId}/terms?include_invited_course_contained=true`,
      token
    );
    const terms = termsData.enrollment_terms || [];
    if (terms.length === 0) return res.json([]);

    // 가장 최근 학기 사용
    const termId = terms[0].id;

    // 3. 해당 학기 강의 목록 (todos)
    const todosData = await canvasApiRequest(
      `/learningx/api/v1/learn_activities/to_dos?term_ids[]=${termId}`,
      token
    );
    const todos = todosData.to_dos || [];

    // 4. 각 강의명 병렬 fetch
    const courses = await Promise.all(
      todos.map(async (todo) => {
        let courseName = `강의 ${todo.course_id}`;
        try {
          const courseData = await canvasApiRequest(
            `/learningx/api/v1/courses/${todo.course_id}`,
            token
          );
          if (courseData.name) courseName = courseData.name;
        } catch {}
        return {
          courseId: todo.course_id,
          courseName,
          incompleteVideos: todo.activities?.total_incompleted_movies || 0,
          courseFormat: '',
        };
      })
    );
    res.json(courses);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// ── Download execution with SSE ────────────────────────────
let currentProcess = null;

app.get('/api/download/start', (req, res) => {
  // Prevent concurrent downloads
  if (currentProcess !== null) {
    res.status(409).json({ error: '이미 다운로드가 진행 중입니다.' });
    return;
  }

  const config = loadConfig();

  const doVideo = req.query.doVideo !== 'false';
  const doFile = req.query.doFile !== 'false';
  const doTranscribe = req.query.doTranscribe !== 'false';
  const doCompress = req.query.doCompress === 'true';
  const compressSize = parseInt(req.query.compressSize) || 200;
  const openedOnly = req.query.openedOnly !== 'false';
  const cpuThreads = parseInt(req.query.cpuThreads) || 0;

  // Parse per-course week filters: {"courseId": "weekFilter", ...}
  let courseWeeks;
  try {
    courseWeeks = JSON.parse(req.query.courseWeeks || '{}');
  } catch {
    res.status(400).json({ error: '올바르지 않은 요청 형식입니다.' });
    return;
  }

  const courseIds = Object.keys(courseWeeks);
  if (courseIds.length === 0) {
    res.status(400).json({ error: '강의를 선택해주세요.' });
    return;
  }

  // Input validation
  for (const id of courseIds) {
    if (!/^\d+$/.test(id)) {
      res.status(400).json({ error: '올바르지 않은 강의 ID 형식입니다.' });
      return;
    }
    const wf = courseWeeks[id];
    if (wf && !/^[0-9,]+$/.test(wf)) {
      res.status(400).json({ error: `올바르지 않은 주차 필터 형식입니다: ${wf}` });
      return;
    }
  }

  // SSE headers
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders();

  const sendEvent = (type, data, courseId) => {
    res.write(`data: ${JSON.stringify({ type, data, courseId: courseId || null })}\n\n`);
  };

  const scriptPath = config.scriptPath || DEFAULT_SCRIPT_PATH;
  const env = {
    ...process.env,
    CANVAS_TOKEN: config.learningxToken || '',
    OPENAI_API_KEY: config.openaiApiKey || '',
    COOKIES_FILE: config.cookiesFile || '',
    FFMPEG_THREADS: String(cpuThreads),
  };

  // Group courses by week filter to minimize script runs
  const groups = {};
  for (const [id, wf] of Object.entries(courseWeeks)) {
    const key = wf || '';
    if (!groups[key]) groups[key] = [];
    groups[key].push(id);
  }

  // Each courseId gets its own script run (parallel)
  const jobs = [];
  for (const [id, wf] of Object.entries(courseWeeks)) {
    jobs.push({ courseId: id, weekFilter: wf || '' });
  }

  let cancelled = false;
  const children = [];
  let completed = 0;

  sendEvent('status', `다운로드를 시작합니다... (${jobs.length}개 강의, 병렬 실행)`);

  for (const job of jobs) {
    const args = ['-c', job.courseId];
    if (config.outputDir) args.push('-o', config.outputDir);
    if (job.weekFilter) args.push('-w', job.weekFilter);
    if (!doVideo) args.push('--no-video');
    if (!doFile) args.push('--no-file');
    if (!doTranscribe) args.push('--no-transcribe');
    if (doCompress) args.push('--compress-mb', String(compressSize));
    if (!openedOnly) args.push('--all');

    const weekLabel = job.weekFilter ? `${job.weekFilter}주차` : '전체';
    sendEvent('course_start', weekLabel, job.courseId);

    const child = spawn('bash', [scriptPath, ...args], { env, cwd: process.env.HOME });
    children.push(child);

    child.stdout.on('data', (data) => {
      if (cancelled) return;
      const lines = data.toString().split('\n').filter(Boolean);
      for (const line of lines) {
        const parsed = parseLine(line);
        sendEvent(parsed.type, parsed.text, job.courseId);
      }
    });

    child.stderr.on('data', (data) => {
      if (cancelled) return;
      const lines = data.toString().split('\n').filter(Boolean);
      for (const line of lines) {
        const parsed = parseLine(line);
        sendEvent(parsed.type, parsed.text, job.courseId);
      }
    });

    child.on('close', (code) => {
      completed++;
      if (code === null && !cancelled) {
        sendEvent('course_done', '취소됨', job.courseId);
      } else {
        sendEvent('course_done', `완료 (종료 코드: ${code})`, job.courseId);
      }

      if (completed >= jobs.length) {
        currentProcess = null;
        if (cancelled) {
          sendEvent('cancelled', '다운로드가 취소되었습니다.');
        } else {
          sendEvent('complete', '모든 다운로드가 완료되었습니다.');
        }
        res.end();
      }
    });

    child.on('error', (err) => {
      completed++;
      sendEvent('error', `강의 ${job.courseId} 실행 오류: ${err.message}`);
      if (completed >= jobs.length) {
        currentProcess = null;
        res.end();
      }
    });
  }

  activeChildren = children;
  currentProcess = children[0] || null;

  req.on('close', () => {
    cancelled = true;
    for (const child of children) {
      try { child.kill('SIGTERM'); } catch {}
    }
    activeChildren = [];
    currentProcess = null;
  });
});

let activeChildren = [];

app.post('/api/download/stop', (req, res) => {
  if (activeChildren.length > 0) {
    for (const child of activeChildren) {
      try { child.kill('SIGTERM'); } catch {}
    }
    activeChildren = [];
    currentProcess = null;
    res.json({ success: true, message: '다운로드가 취소되었습니다.' });
  } else if (currentProcess) {
    currentProcess.kill('SIGTERM');
    currentProcess = null;
    res.json({ success: true, message: '다운로드가 취소되었습니다.' });
  } else {
    res.json({ success: false, message: '실행 중인 다운로드가 없습니다.' });
  }
});

// ── Line parser ────────────────────────────────────────────
function parseLine(line) {
  const trimmed = line.trim();

  if (trimmed.startsWith('[VIDEO] 완료') || trimmed.startsWith('[FILE] 완료') || trimmed.startsWith('[TRANSCRIBE] 완료') || trimmed.startsWith('[MD] 완료')) {
    return { type: 'success', text: trimmed };
  }
  if (trimmed.startsWith('[VIDEO] 다운로드') || trimmed.startsWith('[FILE] 다운로드')) {
    return { type: 'download', text: trimmed };
  }
  if (trimmed.startsWith('[TRANSCRIBE] 시작') || trimmed.startsWith('[TRANSCRIBE] 청크')) {
    return { type: 'transcribe', text: trimmed };
  }
  if (trimmed.startsWith('[SKIP]')) {
    return { type: 'skip', text: trimmed };
  }
  if (trimmed.startsWith('[VIDEO] 실패') || trimmed.startsWith('[FILE] 실패') || trimmed.startsWith('[TRANSCRIBE] 실패')) {
    return { type: 'item_error', text: trimmed };
  }
  if (trimmed.startsWith('Error:')) {
    return { type: 'error', text: trimmed };
  }
  if (trimmed.startsWith('Warning:')) {
    return { type: 'warning', text: trimmed };
  }
  if (trimmed.startsWith('═') || trimmed.startsWith('─') || trimmed.startsWith('────') || trimmed.startsWith('####')) {
    return { type: 'header', text: trimmed };
  }
  if (trimmed.includes('완료')) {
    return { type: 'success', text: trimmed };
  }
  return { type: 'info', text: trimmed };
}

// ── Start server ───────────────────────────────────────────
app.listen(PORT, '127.0.0.1', () => {
  console.log(`LMS Downloader GUI running at http://localhost:${PORT}`);
});
