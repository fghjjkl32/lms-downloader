const express = require('express');
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const https = require('https');

const app = express();
const PORT = 8080;

// The desktop app points this at its userData folder; `npm start` keeps using the repo folder
const DATA_DIR = process.env.LMS_DATA_DIR || __dirname;
const CONFIG_PATH = path.join(DATA_DIR, 'config.json');
const COOKIE_PATH = path.join(DATA_DIR, 'cookies.txt');
const SCRIPT_PATH = path.join(__dirname, 'lms_download.sh');

// Block DNS rebinding: only accept requests addressed to this machine
const ALLOWED_HOSTS = new Set([`localhost:${PORT}`, `127.0.0.1:${PORT}`]);
app.use((req, res, next) => {
  if (!ALLOWED_HOSTS.has(req.headers.host)) {
    return res.status(403).send('Forbidden');
  }
  next();
});

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
      // scriptPath is no longer configurable: always run the bundled script
      delete cfg.scriptPath;
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
  // local: free on-device mlx-whisper, openai: paid API key, server: any OpenAI-compatible URL
  transcribeEngine: 'local',
  whisperUrl: '',
  whisperModel: '',
  outputDir: path.join(DATA_DIR, 'output'),
};

// Config and cookies hold secrets, so keep them readable by the owner only
function writePrivateFile(filePath, content) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, { mode: 0o600 });
  fs.chmodSync(filePath, 0o600);
}

function saveConfig(config) {
  writePrivateFile(CONFIG_PATH, JSON.stringify(config, null, 2));
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
    transcribeEngine: config.transcribeEngine,
    whisperUrl: config.whisperUrl,
    whisperModel: config.whisperModel,
    openaiApiKey: config.openaiApiKey ? '••••••' + config.openaiApiKey.slice(-4) : '',
    learningxToken: config.learningxToken ? '••••••' + config.learningxToken.slice(-8) : '',
    learningxTokenExpiry: config.learningxToken ? getJwtExpiry(config.learningxToken) : null,
    hasOpenaiKey: !!config.openaiApiKey,
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
  if (req.body.outputDir !== undefined) updated.outputDir = req.body.outputDir;
  if (req.body.transcribeEngine !== undefined) {
    if (!['local', 'openai', 'server'].includes(req.body.transcribeEngine)) {
      return res.status(400).json({ error: '알 수 없는 음성 인식 방식입니다.' });
    }
    updated.transcribeEngine = req.body.transcribeEngine;
  }
  if (req.body.whisperUrl !== undefined) {
    if (req.body.whisperUrl && !/^https?:\/\//.test(req.body.whisperUrl)) {
      return res.status(400).json({ error: '음성 인식 서버 주소는 http:// 또는 https://로 시작해야 합니다.' });
    }
    updated.whisperUrl = req.body.whisperUrl;
  }
  if (req.body.whisperModel !== undefined) updated.whisperModel = req.body.whisperModel;

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
    const cookiePath = COOKIE_PATH;
    writePrivateFile(cookiePath, content);

    // Auto-extract xn_api_token as learningxToken
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

// learningx 토큰과 사용자 ID를 꺼낸다. 실패하면 응답을 보내고 null을 돌려준다
function requireLearningxUser(res) {
  const token = loadConfig().learningxToken;
  if (!token) {
    res.status(400).json({ error: 'Canvas에 로그인하거나 쿠키 파일을 먼저 업로드해주세요.' });
    return null;
  }
  const userId = getUserIdFromToken(token);
  if (!userId) {
    res.status(400).json({ error: '토큰에서 사용자 ID를 추출할 수 없습니다.' });
    return null;
  }
  return { token, userId };
}

// Canvas API proxy: 학기 목록
app.get('/api/canvas/terms', async (req, res) => {
  try {
    const auth = requireLearningxUser(res);
    if (!auth) return;
    const termsData = await canvasApiRequest(
      `/learningx/api/v1/users/${auth.userId}/terms?include_invited_course_contained=true`,
      auth.token
    );
    res.json((termsData.enrollment_terms || []).map((t) => ({ id: t.id, name: t.name })));
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Canvas API proxy: 강의 목록 (learningx API 사용)
app.get('/api/canvas/courses', async (req, res) => {
  try {
    const auth = requireLearningxUser(res);
    if (!auth) return;
    const { token } = auth;

    // termId가 없으면 가장 최근 학기를 쓴다
    let termId = req.query.termId;
    if (termId !== undefined && !/^\d+$/.test(termId)) {
      return res.status(400).json({ error: '올바르지 않은 학기 ID 형식입니다.' });
    }
    if (termId === undefined) {
      const termsData = await canvasApiRequest(
        `/learningx/api/v1/users/${auth.userId}/terms?include_invited_course_contained=true`,
        token
      );
      const terms = termsData.enrollment_terms || [];
      if (terms.length === 0) return res.json([]);
      termId = terms[0].id;
    }

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
// Each job runs in its own process group so stopping also kills its curl/ffmpeg children
const activeJobs = new Set();
let cancelCurrentRun = null;

function killJob(child) {
  try { process.kill(-child.pid, 'SIGTERM'); } catch {}
}

function stopAllDownloads() {
  for (const child of activeJobs) killJob(child);
}

// Detached jobs outlive the server unless killed explicitly
process.on('exit', stopAllDownloads);
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    stopAllDownloads();
    process.exit(0);
  });
}

app.get('/api/download/start', (req, res) => {
  // Prevent concurrent downloads (stopped jobs count until they actually exit)
  if (activeJobs.size > 0) {
    res.status(409).json({ error: '이미 다운로드가 진행 중입니다.' });
    return;
  }

  const config = loadConfig();

  const doVideo = req.query.doVideo !== 'false';
  const doFile = req.query.doFile !== 'false';
  const doAttach = req.query.doAttach !== 'false';
  const doSrt = req.query.doSrt === 'true';
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

  const env = {
    ...process.env,
    CANVAS_TOKEN: config.learningxToken || '',
    OPENAI_API_KEY: config.openaiApiKey || '',
    COOKIES_FILE: config.cookiesFile || '',
    FFMPEG_THREADS: String(cpuThreads),
  };
  env.TRANSCRIBE_ENGINE = config.transcribeEngine || 'local';
  env.WHISPER_VENV = path.join(DATA_DIR, 'whisper-venv');
  if (config.whisperUrl) env.WHISPER_URL = config.whisperUrl;
  if (config.whisperModel) env.WHISPER_MODEL = config.whisperModel;

  // Each courseId gets its own script run (parallel)
  const jobs = Object.entries(courseWeeks).map(([id, wf]) => ({ courseId: id, weekFilter: wf || '' }));

  let cancelled = false;
  const children = [];
  let completed = 0;

  const cancelRun = () => {
    cancelled = true;
    for (const child of children) killJob(child);
  };
  cancelCurrentRun = cancelRun;

  sendEvent('status', `다운로드를 시작합니다... (${jobs.length}개 강의, 병렬 실행)`);

  for (const job of jobs) {
    const args = ['-c', job.courseId];
    if (config.outputDir) args.push('-o', config.outputDir);
    if (job.weekFilter) args.push('-w', job.weekFilter);
    // 영상을 끄고 음성 인식만 켜면 영상은 임시로 받아 변환한 뒤 지운다
    if (!doVideo) args.push(doTranscribe ? '--no-keep-video' : '--no-video');
    if (!doFile) args.push('--no-file');
    if (!doAttach) args.push('--no-attach');
    if (doSrt) args.push('--srt');
    if (!doTranscribe) args.push('--no-transcribe');
    if (doCompress) args.push('--compress-mb', String(compressSize));
    if (!openedOnly) args.push('--all');

    const weekLabel = job.weekFilter ? `${job.weekFilter}주차` : '전체';
    sendEvent('course_start', weekLabel, job.courseId);

    const child = spawn('bash', [SCRIPT_PATH, ...args], { env, cwd: process.env.HOME, detached: true });
    children.push(child);
    activeJobs.add(child);

    const forwardOutput = (data) => {
      if (cancelled) return;
      const lines = data.toString().split('\n').filter(Boolean);
      for (const line of lines) {
        const parsed = parseLine(line);
        sendEvent(parsed.type, parsed.text, job.courseId);
      }
    };
    child.stdout.on('data', forwardOutput);
    child.stderr.on('data', forwardOutput);

    // 'error' and 'close' can both fire for one child; count it once
    let finished = false;
    const finishJob = () => {
      if (finished) return;
      finished = true;
      activeJobs.delete(child);
      completed++;
      if (completed >= jobs.length) {
        if (cancelCurrentRun === cancelRun) cancelCurrentRun = null;
        sendEvent(cancelled ? 'cancelled' : 'complete',
          cancelled ? '다운로드가 취소되었습니다.' : '모든 다운로드가 완료되었습니다.');
        res.end();
      }
    };

    child.on('close', (code) => {
      if (code === null) {
        sendEvent('course_done', '취소됨', job.courseId);
      } else {
        sendEvent('course_done', `완료 (종료 코드: ${code})`, job.courseId);
      }
      finishJob();
    });

    child.on('error', (err) => {
      sendEvent('error', `강의 ${job.courseId} 실행 오류: ${err.message}`);
      finishJob();
    });
  }

  // req 'close' fires once the request is read on recent Node, so watch the response instead
  res.on('close', () => {
    if (!res.writableEnded) cancelRun();
  });
});

app.post('/api/download/stop', (req, res) => {
  if (cancelCurrentRun) {
    cancelCurrentRun();
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
const server = app.listen(PORT, '127.0.0.1', () => {
  console.log(`LMS Downloader GUI running at http://localhost:${PORT}`);
});

// Lets the desktop app wait for the server (or learn the port is taken)
const ready = new Promise((resolve, reject) => {
  server.once('listening', resolve);
  server.once('error', reject);
});
ready.catch((err) => {
  console.error(`Server failed to start: ${err.message}`);
  if (require.main === module) process.exit(1);
});

module.exports = { PORT, ready, stopAllDownloads };
