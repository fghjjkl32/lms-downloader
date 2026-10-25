const path = require('path');
const { app, BrowserWindow, dialog, ipcMain, shell } = require('electron');

// A second launch only focuses the first window; quit before it tries to bind the port
if (!app.requestSingleInstanceLock()) {
  app.exit(0);
}

// Tools installed from inside the app, for users without Homebrew
const BIN_DIR = path.join(app.getPath('userData'), 'bin');
// Finder-launched apps get a bare PATH; the script needs Homebrew's jq/ffmpeg/curl
process.env.PATH = [
  '/opt/homebrew/bin',
  '/usr/local/bin',
  path.join(app.getPath('home'), '.local/bin'),
  process.env.PATH,
  BIN_DIR,
].join(':');
// Keep config, cookies and default output outside the app bundle
process.env.LMS_DATA_DIR = app.getPath('userData');

const { PORT, ready, stopAllDownloads } = require('../server');
const deps = require('./deps');

const APP_URL = `http://localhost:${PORT}`;
const CANVAS_URL = 'https://canvas.ssu.ac.kr/';
// Persisted so the SSO session survives restarts and re-login is usually one click
const LOGIN_PARTITION = 'persist:canvas';

let mainWindow = null;
let loginWindow = null;

// ── Main window ────────────────────────────────────────────
function createMainWindow() {
  mainWindow = new BrowserWindow({
    width: 960,
    height: 900,
    title: 'LMS 다운로더',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  // Links such as the cookie extension page open in the default browser
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
  mainWindow.loadURL(APP_URL);
  mainWindow.on('closed', () => { mainWindow = null; });
}

// ── Canvas login ───────────────────────────────────────────
function isFreshToken(token) {
  try {
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
    return !payload.exp || payload.exp * 1000 > Date.now();
  } catch {
    return false;
  }
}

async function findToken(ses) {
  const cookies = await ses.cookies.get({ name: 'xn_api_token' });
  const fresh = cookies.find((c) => isFreshToken(c.value));
  return fresh ? fresh.value : null;
}

// Same Netscape format that the "Get cookies.txt LOCALLY" extension exports
function toNetscapeLine(c) {
  const bare = c.domain.replace(/^\./, '');
  return [
    (c.httpOnly ? '#HttpOnly_' : '') + (c.hostOnly ? bare : `.${bare}`),
    c.hostOnly ? 'FALSE' : 'TRUE',
    c.path,
    c.secure ? 'TRUE' : 'FALSE',
    Math.floor(c.expirationDate || 0),
    c.name,
    c.value,
  ].join('\t');
}

async function saveLogin(ses) {
  if (!(await findToken(ses))) {
    return { ok: false, message: '로그인이 완료되지 않았습니다. 로그인한 뒤 강의 페이지를 한 번 열어 주세요.' };
  }
  const cookies = (await ses.cookies.get({}))
    .filter((c) => c.domain.replace(/^\./, '').endsWith('ssu.ac.kr'));
  const text = ['# Netscape HTTP Cookie File', ...cookies.map(toNetscapeLine)].join('\n') + '\n';

  // Reuse the upload endpoint so the token extraction stays in one place
  const res = await fetch(`${APP_URL}/api/config/upload-cookie`, {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain' },
    body: text,
  });
  const data = await res.json();
  return res.ok
    ? { ok: true, message: '로그인 완료: 쿠키와 토큰을 저장했습니다.' }
    : { ok: false, message: data.error || '쿠키 저장 실패' };
}

async function canvasGet(ses, apiPath) {
  const res = await ses.fetch(new URL(apiPath, CANVAS_URL).href, { headers: { Accept: 'application/json' } });
  if (!res.ok) return null;
  // Canvas prefixes JSON with while(1); to block JSON hijacking
  return JSON.parse((await res.text()).replace(/^while\(1\);/, ''));
}

// Returns a LearningX page of one of the user's courses, or null while not logged in
async function findTokenPage(ses) {
  if (!(await canvasGet(ses, '/api/v1/users/self'))) return null;
  const courses = await canvasGet(ses, '/api/v1/courses?enrollment_state=active&per_page=50');
  if (!Array.isArray(courses) || courses.length === 0) return null;
  for (const course of courses.slice(0, 5)) {
    const tabs = await canvasGet(ses, `/api/v1/courses/${course.id}/tabs`);
    const tools = Array.isArray(tabs) ? tabs.filter((t) => t.type === 'external' && t.full_url) : [];
    // Prefer the lecture-content tab, which is the LearningX tool that issues the token
    const tool = tools.find((t) => /강의|콘텐츠|학습|learningx/i.test(t.label)) || tools[0];
    if (tool) return tool.full_url;
  }
  return new URL(`/courses/${courses[0].id}`, CANVAS_URL).href;
}

function openLoginWindow() {
  return new Promise((resolve) => {
    loginWindow = new BrowserWindow({
      width: 900,
      height: 800,
      parent: mainWindow,
      title: 'Canvas 로그인',
      webPreferences: { partition: LOGIN_PARTITION },
    });
    const win = loginWindow;
    const ses = win.webContents.session;
    let settled = false;

    const finish = async () => {
      if (settled) return;
      settled = true;
      ses.cookies.removeListener('changed', onCookieChanged);
      let result;
      try {
        result = await saveLogin(ses);
      } catch (e) {
        result = { ok: false, message: `쿠키 저장 실패: ${e.message}` };
      }
      if (!win.isDestroyed()) win.close();
      resolve(result);
    };

    // Give the SSO redirect chain a moment to set the remaining cookies
    const finishSoon = () => setTimeout(finish, 1000);
    let nudged = false;
    let checking = false;

    const onCookieChanged = (_event, cookie, _cause, removed) => {
      if (!removed && cookie.name === 'xn_api_token' && isFreshToken(cookie.value)) finishSoon();
    };
    ses.cookies.on('changed', onCookieChanged);

    // A persisted session may already hold a valid token, which emits no 'changed' event
    win.webContents.on('did-finish-load', async () => {
      if (await findToken(ses)) {
        finishSoon();
        return;
      }
      // Logging in only reaches the Canvas dashboard, which does not issue the token;
      // open a course's LearningX page so the user does not have to find one
      // Redirect chains fire several loads at once; check them one at a time
      if (nudged || checking || settled) return;
      checking = true;
      const target = await findTokenPage(ses).catch(() => null);
      checking = false;
      if (target && !win.isDestroyed() && !settled) {
        nudged = true;
        win.loadURL(target);
      }
    });
    win.on('closed', () => {
      loginWindow = null;
      finish();
    });

    win.loadURL(CANVAS_URL);
  });
}

// ── Output folder picker ───────────────────────────────────
ipcMain.handle('pick-folder', async (_event, defaultPath) => {
  const result = await dialog.showOpenDialog(mainWindow, {
    title: '다운로드 받을 폴더 선택',
    buttonLabel: '이 폴더에 저장',
    defaultPath: defaultPath || app.getPath('downloads'),
    properties: ['openDirectory', 'createDirectory'],
  });
  return result.canceled ? null : result.filePaths[0];
});

// ── Required tools ─────────────────────────────────────────
let installing = null;

function installDeps() {
  if (installing) return installing;
  installing = (async () => {
    try {
      const names = await deps.installMissing(BIN_DIR, (name, i, total) => {
        mainWindow?.setProgressBar((i + 0.5) / total);
        mainWindow?.webContents.send('deps-progress', { name, index: i, total });
      });
      return { ok: true, message: names.length ? `설치 완료: ${names.join(', ')}` : '필요한 도구가 모두 있습니다.' };
    } catch (e) {
      return { ok: false, message: `설치 실패: ${e.message}. 인터넷 연결을 확인한 뒤 다시 시도해 주세요.` };
    } finally {
      mainWindow?.setProgressBar(-1);
      installing = null;
    }
  })();
  return installing;
}

// Asks first; resolves { ok } so callers can stop when the user declines
async function askAndInstallDeps(reason) {
  const todo = deps.missing();
  if (todo.length === 0) return { ok: true, message: '필요한 도구가 모두 있습니다.' };
  const sizeMb = todo.reduce((sum, t) => sum + t.sizeMb, 0);
  const { response } = await dialog.showMessageBox(mainWindow, {
    type: 'question',
    buttons: ['설치', '나중에'],
    defaultId: 0,
    cancelId: 1,
    message: '다운로드에 필요한 도구를 설치할까요?',
    detail: `${reason}\n\n${todo.map((t) => `• ${t.name}: ${t.purpose}`).join('\n')}\n\n`
      + `공식 배포 파일(약 ${sizeMb}MB)을 받아 이 앱 안에만 설치합니다. 관리자 암호나 Homebrew는 필요 없습니다.`,
  });
  if (response !== 0) return { ok: false, declined: true, message: '도구 설치를 건너뛰었습니다. 설정 탭에서 언제든 설치할 수 있습니다.' };
  const result = await installDeps();
  if (result.ok) {
    dialog.showMessageBox(mainWindow, { type: 'info', message: '도구 설치를 마쳤습니다.', detail: result.message });
  } else {
    dialog.showErrorBox('도구 설치 실패', result.message);
  }
  return result;
}

ipcMain.handle('deps-status', () => deps.status());
// Run logs are written by the server into userData/logs
ipcMain.handle('open-logs', async () => {
  const dir = path.join(app.getPath('userData'), 'logs');
  require('fs').mkdirSync(dir, { recursive: true });
  return shell.openPath(dir);
});
ipcMain.handle('deps-install', () => installDeps());
ipcMain.handle('deps-ensure', () => askAndInstallDeps('다운로드를 시작하려면 아래 도구가 필요합니다.'));

ipcMain.handle('canvas-login', () => {
  if (loginWindow) {
    loginWindow.focus();
    return { ok: false, message: '로그인 창이 이미 열려 있습니다.' };
  }
  return openLoginWindow();
});

// ── App lifecycle ──────────────────────────────────────────
app.on('second-instance', () => {
  if (mainWindow) {
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  }
});

app.whenReady().then(async () => {
  try {
    await ready;
  } catch (e) {
    dialog.showErrorBox(
      `포트 ${PORT}를 사용할 수 없습니다`,
      `이미 실행 중인 LMS 다운로더(npm start 등)를 종료한 뒤 다시 열어 주세요.\n\n${e.message}`,
    );
    app.quit();
    return;
  }
  createMainWindow();
  mainWindow.webContents.once('did-finish-load', () => {
    askAndInstallDeps('처음 실행이라 아래 도구를 설치해야 합니다.');
  });
});

app.on('activate', () => {
  if (!mainWindow) createMainWindow();
});

app.on('window-all-closed', () => app.quit());
app.on('before-quit', stopAllDownloads);
