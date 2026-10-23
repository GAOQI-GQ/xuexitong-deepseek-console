import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { requestAnswers } from './deepseek-request.mjs';

const PORT = 37841;
const scriptPath = fileURLToPath(new URL('./xuexitong-console.js', import.meta.url));
const token = randomBytes(24).toString('hex');
const setupToken = randomBytes(18).toString('hex');
const allowedOrigin = (origin) => /^https:\/\/([a-z0-9-]+\.)*chaoxing\.com$/i.test(origin || '');

const CONFIG_DIR = process.env.APPDATA
    ? join(process.env.APPDATA, 'xuexitong-deepseek')
    : join(homedir(), '.xuexitong-deepseek');
const CONFIG_PATH = join(CONFIG_DIR, 'config.json');

function dpapiEncrypt(value) {
    const script = 'Add-Type -AssemblyName System.Security; $b=[Text.Encoding]::UTF8.GetBytes($env:XXT_KEY); [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))';
    return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
        env: { ...process.env, XXT_KEY: value },
        encoding: 'utf8',
        windowsHide: true,
    }).trim();
}

function dpapiDecrypt(value) {
    const script = 'Add-Type -AssemblyName System.Security; $b=[Convert]::FromBase64String($env:XXT_ENC); [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))';
    return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
        env: { ...process.env, XXT_ENC: value },
        encoding: 'utf8',
        windowsHide: true,
    }).trim();
}

function loadSavedKey() {
    try {
        const config = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
        if (!config || !config.key) return '';
        if (config.scheme === 'dpapi') return dpapiDecrypt(config.key);
        if (config.scheme === 'plain') return Buffer.from(config.key, 'base64').toString('utf8');
    } catch (_) { /* 没有保存过，或配置损坏 */ }
    return '';
}

function saveKeyToDisk(value) {
    mkdirSync(CONFIG_DIR, { recursive: true });
    let entry;
    if (process.platform === 'win32') {
        try {
            entry = { scheme: 'dpapi', key: dpapiEncrypt(value) };
        } catch (error) {
            console.warn('Windows 加密不可用，改为本机文件保存:', error.message);
        }
    }
    if (!entry) entry = { scheme: 'plain', key: Buffer.from(value, 'utf8').toString('base64') };
    writeFileSync(CONFIG_PATH, JSON.stringify({ ...entry, savedAt: new Date().toISOString() }, null, 2), { encoding: 'utf8', mode: 0o600 });
}

function clearSavedKey() {
    try { unlinkSync(CONFIG_PATH); } catch (_) { /* 不存在 */ }
}

function maskedKey(value) {
    if (!value) return '';
    if (value.length <= 10) return 'sk-***';
    return `${value.slice(0, 5)}...${value.slice(-4)}`;
}

let apiKey = loadSavedKey();
let savedKeyOnDisk = Boolean(apiKey);

const script = readFileSync(scriptPath, 'utf8');
if (!/const LOCAL_TOKEN = '[^']*';/.test(script)) throw new Error('控制台脚本缺少本地令牌位置');
const scriptWithToken = script.replace(/const LOCAL_TOKEN = '[^']*';/, `const LOCAL_TOKEN = '${token}';`);

function send(res, status, data, origin) {
    res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
        'Access-Control-Allow-Origin': origin,
        'Vary': 'Origin',
    });
    res.end(JSON.stringify(data));
}

function sendJson(res, status, data) {
    res.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
    });
    res.end(JSON.stringify(data));
}

async function readJson(req, limit = 10000) {
    let raw = '';
    for await (const chunk of req) {
        raw += chunk.toString('utf8');
        if (raw.length > limit) throw new Error('请求内容过大');
    }
    return JSON.parse(raw);
}

function setupPage() {
    const hasKey = Boolean(apiKey);
    const masked = maskedKey(apiKey);
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>学习通 DeepSeek 助手</title>
<style>
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#eef2f7;color:#1f2937;font:14px/1.6 system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif;padding:24px}
.card{width:100%;max-width:430px;background:#fff;border:1px solid #e5e7eb;border-radius:16px;box-shadow:0 18px 50px rgba(15,23,42,.12);padding:28px}
h1{margin:0;font-size:20px;letter-spacing:.2px}
.sub{margin:4px 0 20px;color:#6b7280;font-size:13px}
.status{display:flex;align-items:center;gap:8px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:10px;padding:10px 12px;margin-bottom:18px;font-size:13px}
.dot{width:9px;height:9px;border-radius:50%;background:#f59e0b;flex:none}
.dot.ok{background:#22c55e}
.masked{color:#64748b;margin-left:auto;font-family:ui-monospace,Consolas,monospace;font-size:12px}
label{display:block;font-weight:600;margin-bottom:6px;font-size:13px}
.wrap{position:relative}
input[type=password],input[type=text]{width:100%;padding:11px 40px 11px 12px;border:1px solid #cbd5e1;border-radius:9px;font-size:14px;outline:none;background:#fff}
input:focus{border-color:#3b82f6;box-shadow:0 0 0 3px rgba(59,130,246,.15)}
.eye{position:absolute;right:8px;top:50%;transform:translateY(-50%);border:0;background:transparent;color:#64748b;cursor:pointer;padding:4px;font-size:13px}
.row{display:flex;align-items:center;gap:8px;margin:14px 0 16px;color:#475569;font-size:13px}
.row input{width:16px;height:16px;accent-color:#2563eb}
button.primary{width:100%;padding:11px 14px;border:0;border-radius:9px;background:#2563eb;color:#fff;font-size:15px;font-weight:600;cursor:pointer}
button.primary:disabled{opacity:.6;cursor:not-allowed}
.msg{min-height:20px;margin-top:10px;font-size:13px;color:#dc2626}
.msg.ok{color:#16a34a}
.hint{margin-top:18px;padding-top:14px;border-top:1px solid #f1f5f9;color:#94a3b8;font-size:12px;line-height:1.7}
.hint a{color:#2563eb;text-decoration:none}
.clear{margin-top:10px;border:0;background:transparent;color:#94a3b8;font-size:12px;cursor:pointer;text-decoration:underline;padding:0}
</style>
</head>
<body>
<div class="card">
  <h1>学习通 DeepSeek 助手</h1>
  <p class="sub">输入 API Key 后即可开始自动答题。密钥只保存在本机。</p>
  <div class="status">
    <span class="dot" id="dot"></span>
    <span id="statusText">正在读取状态...</span>
    <span class="masked" id="masked"></span>
  </div>
  <label for="key">DeepSeek API Key</label>
  <div class="wrap">
    <input id="key" type="password" autocomplete="off" spellcheck="false" placeholder="sk-...">
    <button class="eye" id="eye" type="button">显示</button>
  </div>
  <div class="row">
    <input id="remember" type="checkbox" checked>
    <label for="remember" style="margin:0;font-weight:400">记住密钥，下次启动自动使用</label>
  </div>
  <button class="primary" id="save" type="button">保存并启动</button>
  <div class="msg" id="msg"></div>
  <button class="clear" id="clear" type="button">清除已保存的密钥</button>
  <div class="hint">
    密钥使用 Windows 当前用户加密保存，不会上传到除 DeepSeek 接口以外的地方。<br>
    还没有 Key？前往 <a href="https://platform.deepseek.com" target="_blank" rel="noreferrer">platform.deepseek.com</a> 创建，API 按量付费。<br>
    设置完成后关闭这个窗口即可，本地服务会继续运行。
  </div>
</div>
<script>
(function () {
  var SETUP_TOKEN = '${setupToken}';
  var input = document.getElementById('key');
  var save = document.getElementById('save');
  var clear = document.getElementById('clear');
  var msg = document.getElementById('msg');
  var dot = document.getElementById('dot');
  var statusText = document.getElementById('statusText');
  var masked = document.getElementById('masked');
  var eye = document.getElementById('eye');

  function setStatus(hasKey, mask) {
    dot.className = 'dot' + (hasKey ? ' ok' : '');
    statusText.textContent = hasKey ? '已配置密钥，服务可用' : '尚未配置密钥';
    masked.textContent = mask || '';
    clear.style.display = hasKey ? 'inline' : 'none';
  }

  function request(path, options) {
    options = options || {};
    options.headers = Object.assign({ 'X-Setup-Token': SETUP_TOKEN }, options.headers || {});
    return fetch(path, options).then(function (res) {
      return res.json().catch(function () { return {}; }).then(function (data) {
        if (!res.ok) throw new Error(data.error || ('HTTP ' + res.status));
        return data;
      });
    });
  }

  request('/api/status').then(function (data) {
    setStatus(data.hasKey, data.masked);
  }).catch(function (error) {
    statusText.textContent = '无法读取状态：' + error.message;
  });

  eye.onclick = function () {
    var show = input.type === 'password';
    input.type = show ? 'text' : 'password';
    eye.textContent = show ? '隐藏' : '显示';
  };

  save.onclick = async function () {
    var key = input.value.trim();
    if (!/^sk-\\S{10,}$/.test(key)) {
      msg.className = 'msg';
      msg.textContent = 'Key 格式不正确，DeepSeek Key 通常以 sk- 开头。';
      return;
    }
    save.disabled = true;
    save.textContent = '验证中...';
    msg.className = 'msg';
    msg.textContent = '';
    try {
      var data = await request('/api/key', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key: key, remember: document.getElementById('remember').checked }),
      });
      input.value = '';
      setStatus(true, data.masked);
      msg.className = 'msg ok';
      msg.textContent = data.warning ? ('已保存。' + data.warning) : '保存成功，可以关闭此窗口了。';
    } catch (error) {
      msg.className = 'msg';
      msg.textContent = error.message;
    } finally {
      save.disabled = false;
      save.textContent = '保存并启动';
    }
  };

  clear.onclick = async function () {
    if (!confirm('确定清除已保存的 API Key？')) return;
    try {
      await request('/api/clear', { method: 'POST' });
      setStatus(false, '');
      msg.className = 'msg ok';
      msg.textContent = '已清除保存的密钥。';
    } catch (error) {
      msg.className = 'msg';
      msg.textContent = error.message;
    }
  };
})();
</script>
</body>
</html>`;
}

function validQuestions(questions) {
    if (!Array.isArray(questions) || questions.length < 1 || questions.length > 30) return false;
    return questions.every((q, i) => Number.isInteger(q.id) && q.id === i + 1 &&
        ['单选题', '多选题', '判断题'].includes(q.type) &&
        typeof q.question === 'string' && q.question.length > 0 && q.question.length <= 500 &&
        Array.isArray(q.options) && q.options.length >= 2 && q.options.length <= 8 &&
        new Set(q.options.map((o) => o.letter)).size === q.options.length &&
        q.options.every((o) => /^[A-H]$/.test(o.letter) && typeof o.text === 'string' && o.text.length > 0 && o.text.length <= 500));
}

let busy = false;
const server = createServer(async (req, res) => {
    const origin = req.headers.origin;

    if (req.method === 'GET' && (req.url === '/' || req.url === '/setup' || req.url === '/favicon.ico')) {
        if (req.url === '/favicon.ico') {
            res.writeHead(204);
            res.end();
            return;
        }
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' });
        res.end(setupPage());
        return;
    }

    if (req.url.startsWith('/api/')) {
        if (req.headers['x-setup-token'] !== setupToken) {
            sendJson(res, 403, { error: '设置页令牌不匹配，请刷新设置页' });
            return;
        }
        if (req.method === 'GET' && req.url === '/api/status') {
            sendJson(res, 200, { hasKey: Boolean(apiKey), masked: maskedKey(apiKey), saved: savedKeyOnDisk });
            return;
        }
        if (req.method === 'POST' && req.url === '/api/clear') {
            apiKey = '';
            savedKeyOnDisk = false;
            clearSavedKey();
            sendJson(res, 200, { ok: true });
            return;
        }
        if (req.method === 'POST' && req.url === '/api/key') {
            let body;
            try {
                body = await readJson(req);
            } catch (error) {
                sendJson(res, 400, { error: error.message });
                return;
            }
            const key = String(body.key || '').trim();
            if (!/^sk-\S{10,}$/.test(key)) {
                sendJson(res, 400, { error: 'Key 格式不正确，DeepSeek Key 通常以 sk- 开头' });
                return;
            }
            let warning = '';
            try {
                const response = await fetch('https://api.deepseek.com/models', {
                    headers: { Authorization: `Bearer ${key}` },
                    signal: AbortSignal.timeout(15000),
                });
                if (response.status === 401 || response.status === 403) {
                    sendJson(res, 400, { error: 'Key 无效或没有权限，请检查后重试' });
                    return;
                }
            } catch (_) {
                warning = '网络验证未完成，已按格式保存。';
            }
            apiKey = key;
            if (body.remember !== false) {
                try {
                    saveKeyToDisk(key);
                    savedKeyOnDisk = true;
                } catch (error) {
                    warning = `密钥已用于本次运行，但保存失败：${error.message}`;
                    savedKeyOnDisk = false;
                }
            } else {
                clearSavedKey();
                savedKeyOnDisk = false;
            }
            console.log(`DeepSeek API Key 已设置（${maskedKey(key)}）`);
            sendJson(res, 200, { ok: true, masked: maskedKey(key), warning });
            return;
        }
        sendJson(res, 404, { error: '未找到接口' });
        return;
    }

    if (!allowedOrigin(origin)) {
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        res.end('Origin not allowed');
        return;
    }
    if (req.method === 'OPTIONS') {
        res.writeHead(204, {
            'Access-Control-Allow-Origin': origin,
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
            'Access-Control-Allow-Headers': 'Content-Type, X-Xuexitong-Token',
            'Access-Control-Allow-Private-Network': 'true',
            'Access-Control-Max-Age': '600',
            'Vary': 'Origin',
        });
        res.end();
        return;
    }
    if (req.method === 'GET' && req.url === '/script') {
        res.writeHead(200, {
            'Content-Type': 'text/javascript; charset=utf-8',
            'Cache-Control': 'no-store',
            'Access-Control-Allow-Origin': origin,
            'Access-Control-Allow-Private-Network': 'true',
            'Vary': 'Origin',
        });
        res.end(scriptWithToken);
        return;
    }
    if (req.headers['x-xuexitong-token'] !== token) {
        send(res, 403, { error: '本地令牌不匹配，请重新复制控制台脚本' }, origin);
        return;
    }
    if (req.method === 'GET' && req.url === '/health') {
        send(res, 200, { ok: true, hasKey: Boolean(apiKey) }, origin);
        return;
    }
    if (req.method !== 'POST' || req.url !== '/answer') {
        send(res, 404, { error: '未找到接口' }, origin);
        return;
    }
    if (!apiKey) {
        send(res, 409, { error: '尚未设置 DeepSeek API Key，请打开 http://127.0.0.1:37841/setup 设置' }, origin);
        return;
    }
    if (busy) {
        send(res, 429, { error: '上一批题目仍在处理' }, origin);
        return;
    }
    if (!String(req.headers['content-type'] || '').startsWith('application/json')) {
        send(res, 415, { error: '仅接受 JSON' }, origin);
        return;
    }
    busy = true;
    try {
        let raw = '';
        for await (const chunk of req) {
            raw += chunk.toString('utf8');
            if (raw.length > 100000) throw new Error('请求内容过大');
        }
        const questions = JSON.parse(raw).questions;
        if (!validQuestions(questions)) throw new Error('题目格式不正确');
        const answers = await requestAnswers(questions, apiKey);
        send(res, 200, { answers }, origin);
    } catch (error) {
        send(res, 502, { error: error.message }, origin);
    } finally {
        busy = false;
    }
});

function openSetupPage() {
    if (process.env.XXT_NO_BROWSER === '1') return;
    const url = `http://127.0.0.1:${PORT}/setup`;
    const candidates = [
        process.env['ProgramFiles(x86)'] && join(process.env['ProgramFiles(x86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
        process.env.ProgramFiles && join(process.env.ProgramFiles, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    ].filter(Boolean);
    const edge = candidates.find((candidate) => existsSync(candidate));
    try {
        if (edge) {
            spawn(edge, [`--app=${url}`, '--window-size=480,720'], { detached: true, stdio: 'ignore' }).unref();
            return;
        }
        if (process.platform === 'win32') {
            spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
            return;
        }
        spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
    } catch (error) {
        console.warn('无法自动打开设置页，请手动访问：' + url);
    }
}

server.listen(PORT, '127.0.0.1', () => {
    writeFileSync(scriptPath, scriptWithToken, 'utf8');
    console.log(`本地服务已启动：http://127.0.0.1:${PORT}`);
    console.log(`可视化设置页：http://127.0.0.1:${PORT}/setup`);
    if (apiKey) {
        console.log(`已加载保存的 API Key（${maskedKey(apiKey)}），无需重新输入。`);
    } else {
        console.log('尚未设置 API Key，正在打开设置窗口...');
        openSetupPage();
    }
    console.log('方式一：复制同目录 xuexitong-console.js 的全部内容，粘贴到学习通页面的 Edge 控制台并按 Enter。');
    console.log('方式二（推荐）：在学习通页面点击“学习通自动答题”书签，自动拉取本次启动的脚本，无需 DevTools。');
    console.log('关闭本窗口即可停止服务。');
});
