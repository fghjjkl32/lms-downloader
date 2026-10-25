const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const zlib = require('zlib');
const { execFileSync } = require('child_process');

// Pinned official release builds, so users without Homebrew can install from inside the app.
// Checksums for jq and uv match the published sha256 files; ffmpeg-static publishes none, so it is pinned here.
const TOOLS = [
  {
    name: 'jq',
    purpose: '강의 정보 처리',
    url: 'https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-macos-arm64',
    sha256: '2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e',
    sizeMb: 1,
    unpack: 'raw',
  },
  {
    name: 'ffmpeg',
    purpose: '음성 추출, 영상 압축',
    url: 'https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64.gz',
    sha256: '8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa',
    sizeMb: 19,
    unpack: 'gzip',
  },
  {
    name: 'ffprobe',
    purpose: '영상 길이 확인',
    url: 'https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-arm64.gz',
    sha256: 'd986a8ec7b030899fe66a8a288ed809a3543338705a3ce178cfb85869c5d80be',
    sizeMb: 19,
    unpack: 'gzip',
  },
  {
    name: 'uv',
    purpose: '무료 음성 인식 엔진 설치',
    url: 'https://github.com/astral-sh/uv/releases/download/0.13.5/uv-aarch64-apple-darwin.tar.gz',
    sha256: '743f85035a1996ecb350659e01cd9faea9709829be09b1b4b03c73eaf3c9cd73',
    sizeMb: 14,
    unpack: 'tar',
    member: 'uv-aarch64-apple-darwin/uv',
  },
];

function findOnPath(name) {
  for (const dir of (process.env.PATH || '').split(':')) {
    if (!dir) continue;
    const file = path.join(dir, name);
    try {
      fs.accessSync(file, fs.constants.X_OK);
      if (fs.statSync(file).isFile()) return file;
    } catch {
      // not in this directory
    }
  }
  return null;
}

function status() {
  return TOOLS.map((t) => ({ name: t.name, purpose: t.purpose, sizeMb: t.sizeMb, path: findOnPath(t.name) }));
}

function missing() {
  return TOOLS.filter((t) => !findOnPath(t.name));
}

async function download(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return Buffer.from(await res.arrayBuffer());
}

function unpack(tool, data) {
  if (tool.unpack === 'raw') return data;
  if (tool.unpack === 'gzip') return zlib.gunzipSync(data);
  // tar.gz: let the system tar extract the one member we need
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lms-deps-'));
  try {
    const archive = path.join(tmp, 'archive.tar.gz');
    fs.writeFileSync(archive, data);
    execFileSync('/usr/bin/tar', ['-xzf', archive, '-C', tmp, tool.member]);
    return fs.readFileSync(path.join(tmp, tool.member));
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// Installs every missing tool into binDir; onProgress(name, index, total) runs before each one
async function installMissing(binDir, onProgress = () => {}) {
  const todo = missing();
  fs.mkdirSync(binDir, { recursive: true });
  for (const [i, tool] of todo.entries()) {
    onProgress(tool.name, i, todo.length);
    const data = await download(tool.url);
    const digest = crypto.createHash('sha256').update(data).digest('hex');
    if (digest !== tool.sha256) throw new Error(`${tool.name} 파일이 손상되었습니다 (체크섬 불일치)`);
    const dest = path.join(binDir, tool.name);
    fs.writeFileSync(`${dest}.part`, unpack(tool, data), { mode: 0o755 });
    fs.renameSync(`${dest}.part`, dest);
  }
  return todo.map((t) => t.name);
}

module.exports = { status, missing, installMissing };
