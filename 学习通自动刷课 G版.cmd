@echo off
if /i "%~1"=="--minimized" goto :run
start "" /min "%~f0" --minimized
exit /b 0

:run
chcp 65001 >nul
setlocal
title DeepSeek Local Service
set "XXT_SELF=%~f0"
set "XXT_TMP=%TEMP%\xuexitong-deepseek"
if not exist "%XXT_TMP%" mkdir "%XXT_TMP%" >nul 2>nul
set "XXT_SERVER=%XXT_TMP%\server.mjs"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:XXT_SELF; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); $a=':__XXT_SERVER_'+'START__'; $b=':__XXT_SERVER_'+'END__'; $i=$t.IndexOf($a); $j=$t.IndexOf($b,$i+$a.Length); if($i -lt 0 -or $j -lt 0){exit 1}; $code=$t.Substring($i+$a.Length,$j-$i-$a.Length).Trim(); [IO.File]::WriteAllText($env:XXT_SERVER,$code,[Text.UTF8Encoding]::new($false))"
if errorlevel 1 (
  echo Failed to prepare the server. Please send me the exact message above.
  goto :failed
)

set "NODE_EXE=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
if not exist "%NODE_EXE%" (
  set "NODE_EXE="
  for /f "delims=" %%I in ('where node.exe 2^>nul') do if not defined NODE_EXE set "NODE_EXE=%%I"
)
if not defined NODE_EXE (
  echo Node.js was not found. Install Node.js and try again.
  goto :failed
)

echo Starting DeepSeek local service...
"%NODE_EXE%" "%XXT_SERVER%"
set "EXIT_CODE=%ERRORLEVEL%"
del "%XXT_SERVER%" >nul 2>nul
echo.
echo Local service exited with code %EXIT_CODE%.
echo If there is an error above, please send me the exact text.
pause
exit /b %EXIT_CODE%

:failed
echo.
echo Startup failed. Please send me the exact message above.
pause
exit /b 1

:__XXT_SERVER_START__
import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { spawn, execFileSync } from 'node:child_process';

const PORT = Number(process.env.XXT_PORT) || 37841;
const token = randomBytes(24).toString('hex');
const setupToken = randomBytes(18).toString('hex');
const BROWSER_START = ':__XXT_BROWSER_' + 'START__';
const BROWSER_END = ':__XXT_BROWSER_' + 'END__';

const API_URL = 'https://api.deepseek.com/chat/completions';
const ATTEMPTS = [
    { thinking: { type: 'enabled' }, reasoning_effort: 'low', max_tokens: 16000 },
    { thinking: { type: 'disabled' }, max_tokens: 8000 },
];

async function requestAnswers(questions, apiKey, fetchImpl = fetch) {
    let lastProblem = '';
    for (const [index, settings] of ATTEMPTS.entries()) {
        const body = {
            model: 'deepseek-flash',
            stream: false,
            response_format: { type: 'json_object' },
            ...settings,
            messages: [
                { role: 'system', content: '按题意回答全部题目。注意：题干或选项可能经过网页防复制处理，出现个别汉字被替换、插入无关字，或词语看起来不通顺。先结合上下文和选项在内部还原最可能的原句，再按还原后的题意作答；不要把明显异常的替换字当作专业术语，也不要因无法逐字还原而放弃。每题都必须给非空答案，只用该题提供的选项字母且不可重复；单选和判断选一个，多选列出所有正确项。不确定时选最可能的答案。id须对应题号。只输出JSON：{"answers":[{"id":1,"letters":["A"]}]}。' },
                { role: 'user', content: JSON.stringify(questions) },
            ],
        };
        let response;
        try {
            response = await fetchImpl(API_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
                body: JSON.stringify(body),
                signal: AbortSignal.timeout(240000),
            });
        } catch (error) {
            if (index + 1 < ATTEMPTS.length && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
                lastProblem = 'DeepSeek 请求超时（240 秒）';
                console.warn(`${lastProblem}，改用降级配置重试`);
                continue;
            }
            throw error;
        }
        const data = await response.json().catch(() => null);
        if (!response.ok) {
            const detail = data?.error?.message || data?.error || data?.message || '';
            const message = `DeepSeek API 返回 HTTP ${response.status}${detail ? `：${detail}` : ''}`;
            if (response.status === 400 && index + 1 < ATTEMPTS.length && /max_tokens|token|length|thinking|reasoning|parameter/i.test(detail)) {
                lastProblem = message;
                console.warn(`${message}，改用降级配置重试`);
                continue;
            }
            throw new Error(message);
        }
        const choice = data?.choices?.[0];
        const reason = choice?.finish_reason;
        if (reason === 'length') {
            lastProblem = `DeepSeek 输出达到长度上限（已生成 ${data.usage?.completion_tokens ?? '未知'} tokens）`;
        } else if (reason !== 'stop') {
            throw new Error(`DeepSeek 未正常结束（finish_reason=${reason ?? '缺失'}）`);
        } else {
            try {
                const answer = JSON.parse(choice.message?.content || '');
                if (Array.isArray(answer.answers) && answer.answers.length === questions.length) return answer.answers;
                lastProblem = 'DeepSeek 返回格式不完整';
            } catch {
                lastProblem = 'DeepSeek 返回空内容或无法解析 JSON';
            }
        }
        if (index + 1 < ATTEMPTS.length) console.warn(`${lastProblem}，正在重试`);
    }
    throw new Error(`${lastProblem}；重试后仍未获得完整答案，没有选择或提交题目`);
}

function readBrowserSource() {
    const sourcePath = process.env.XXT_SELF;
    if (!sourcePath) throw new Error('请通过“学习通自动刷课 G版.cmd”启动本地服务');
    const text = readFileSync(sourcePath, 'utf8');
    const start = text.indexOf(BROWSER_START);
    if (start < 0) throw new Error('单文件启动器缺少浏览器脚本起始标记');
    const end = text.indexOf(BROWSER_END, start + BROWSER_START.length);
    if (end < 0) throw new Error('单文件启动器缺少浏览器脚本结束标记');
    return text.slice(start + BROWSER_START.length, end).replace(/^\r?\n/, '').replace(/\r?\n$/, '');
}
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

const script = readBrowserSource();
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
            openChaoxingPage();
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
        send(res, 403, { error: '本地令牌不匹配，请刷新学习通页面后重新点击书签' }, origin);
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

function findEdge() {
    const candidates = [
        process.env['ProgramFiles(x86)'] && join(process.env['ProgramFiles(x86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
        process.env.ProgramFiles && join(process.env.ProgramFiles, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    ].filter(Boolean);
    return candidates.find((candidate) => existsSync(candidate));
}

function openSetupPage() {
    if (process.env.XXT_NO_BROWSER === '1') return;
    const url = `http://127.0.0.1:${PORT}/setup`;
    const edge = findEdge();
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

const CHAOXING_URL = 'https://i.chaoxing.com/';
let chaoxingOpened = false;

function openChaoxingPage() {
    if (process.env.XXT_NO_BROWSER === '1' || chaoxingOpened) return;
    chaoxingOpened = true;
    const edge = findEdge();
    try {
        if (edge) {
            spawn(edge, ['--new-window', CHAOXING_URL], { detached: true, stdio: 'ignore' }).unref();
            console.log('已在 Edge 打开学习通：' + CHAOXING_URL);
            return;
        }
        if (process.platform === 'win32') {
            spawn('cmd', ['/c', 'start', '', CHAOXING_URL], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
            console.log('已用默认浏览器打开学习通：' + CHAOXING_URL);
            return;
        }
        spawn('xdg-open', [CHAOXING_URL], { detached: true, stdio: 'ignore' }).unref();
    } catch (error) {
        chaoxingOpened = false;
        console.warn('无法自动打开学习通，请手动访问：' + CHAOXING_URL);
    }
}

// 端口被旧实例占用时给出可读提示，而不是抛出 Node 堆栈
server.on('error', (error) => {
    if (error && error.code === 'EADDRINUSE') {
        console.error(`端口 ${PORT} 已被占用：可能之前启动的服务窗口还没关闭。请关闭旧的 DeepSeek Local Service 窗口后重新启动。`);
    } else {
        console.error('本地服务启动失败：', error && error.message ? error.message : error);
    }
    if (!server.listening) process.exit(1);
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`本地服务已启动：http://127.0.0.1:${PORT}`);
    console.log(`可视化设置页：http://127.0.0.1:${PORT}/setup`);
    if (apiKey) {
        console.log(`已加载保存的 API Key（${maskedKey(apiKey)}），无需重新输入。`);
    } else {
        console.log('尚未设置 API Key，正在打开设置窗口...');
    }
    openChaoxingPage();
    if (!apiKey) openSetupPage();
    console.log('注入方式：在学习通课程页点击“学习通自动答题”书签，自动拉取本次启动的脚本，无需 DevTools。');
    console.log('关闭本窗口即可停止服务。');
});
:__XXT_SERVER_END__
:__XXT_BROWSER_START__
(function xuexitongMain() {
const PAGE = window;
const $ = (...args) => PAGE.jQuery(...args);
const APP_KEY = '__xuexitongConsoleDeepSeek';
const BOOT_TIMER_KEY = '__xuexitongConsoleDeepSeekBootTimer';
const LOCAL_URL = 'http://127.0.0.1:37841';
const LOCAL_TOKEN = '__LOCAL_TOKEN__';
const DIRECT_MODE = typeof PAGE.__deepseekAsk === 'function';
const startedByKeeper = PAGE.__xuexitongAutoInjected === true;
delete PAGE.__xuexitongAutoInjected;
if (!/^https:\/\/([a-z0-9-]+\.)*chaoxing\.com$/i.test(location.origin) ||
!location.pathname.includes('/mycourse/studentstudy')) {
console.error('请在学习通课程播放页的控制台执行本脚本');
return;
}
if (!DIRECT_MODE && LOCAL_TOKEN === '__LOCAL_TOKEN__') {
console.error('请先启动 DeepSeek 本地服务，再点击书签注入');
return;
}

// 清理旧实例失败也不能影响本次注入
const destroyQuietly = (instance) => {
try {
if (instance && typeof instance.destroy === 'function') instance.destroy();
} catch (error) {
console.warn('清理旧实例失败，已忽略:', error);
}
};
destroyQuietly(PAGE[APP_KEY]);
destroyQuietly(PAGE.__xuexitongPlayerV3);
destroyQuietly(PAGE.__xuexitongPlayerV800DeepSeek);
if (PAGE[BOOT_TIMER_KEY]) {
clearInterval(PAGE[BOOT_TIMER_KEY]);
PAGE[BOOT_TIMER_KEY] = null;
}
if (!startedByKeeper) installNavigationKeeper();
if (DIRECT_MODE) {
console.log('%cDeepSeek 直连模式已就绪', 'color:#4CAF50;font-weight:bold');
startPlayer();
} else {
fetch(`${LOCAL_URL}/health`, {
headers: { 'X-Xuexitong-Token': LOCAL_TOKEN },
signal: AbortSignal.timeout(5000),
}).then((response) => {
if (!response.ok) throw new Error(`HTTP ${response.status}`);
console.log('DeepSeek 本地服务已连接');
startPlayer();
}).catch((error) => console.error('DeepSeek 本地服务不可用，请先启动服务并检查 Edge 本地网络权限:', error));
}

function startPlayer() {
if (typeof PAGE.jQuery === 'undefined') {
const script = document.createElement('script');
script.src = 'https://code.jquery.com/jquery-3.6.0.min.js';
script.type = 'text/javascript';
script.onload = function () {
console.log('jQuery loaded.');
waitForCoursePage();
};
script.onerror = () => console.error('jQuery 加载失败，脚本无法启动');
(document.head || document.documentElement).appendChild(script);
} else {
waitForCoursePage();
}
}

function installNavigationKeeper() {
let keeper;
try {
keeper = PAGE.open('', 'xuexitongConsoleKeeper', 'width=360,height=150');
if (!keeper) throw new Error('浏览器阻止了辅助窗口');
keeper.document.title = '学习通自动任务辅助窗口';
keeper.document.body.innerHTML = '<p style="font:16px sans-serif;padding:12px">GQ提醒您：学习通自动任务正在运行。请保持此窗口打开；课程页整页跳转后，它会重新启动脚本。</p>';
keeper.__xuexitongSource = `(${xuexitongMain.toString()})();`;
keeper.__xuexitongLastUrl = location.href;
keeper.__xuexitongLastInjectionAt = Date.now();
if (!keeper.__xuexitongKeeperTimer) {
keeper.eval(`window.__xuexitongKeeperTimer = setInterval(function () {
                    try {
                        var page = window.opener;
                        if (!page || page.closed) { clearInterval(window.__xuexitongKeeperTimer); window.close(); return; }
                        if (!/^https:\\/\\/([a-z0-9-]+\\.)*chaoxing\\.com\\/mycourse\\/studentstudy/i.test(page.location.href)) return;
                        if (page.location.href !== window.__xuexitongLastUrl) {
                            window.__xuexitongLastUrl = page.location.href;
                            window.__xuexitongLastInjectionAt = Date.now() - 30000;
                        }
                        if (page.document.readyState !== 'complete' || !page.document.querySelector('#coursetree')) return;
                        if (page.__xuexitongConsoleDeepSeek || page.__xuexitongConsoleDeepSeekBootTimer) return;
                        if (Date.now() - window.__xuexitongLastInjectionAt < 30000) return;
                        window.__xuexitongLastInjectionAt = Date.now();
                        page.__xuexitongAutoInjected = true;
                        page.eval(window.__xuexitongSource);
                    } catch (error) {
                        if (Date.now() - (window.__xuexitongLastErrorAt || 0) > 30000) {
                            window.__xuexitongLastErrorAt = Date.now();
                            window.document.body.textContent = '整页跳转后的自动恢复遇到错误：' + error.message;
                            console.warn('学习通整页跳转后的自动恢复暂不可用:', error);
                        }
                    }
                }, 1000);`);
}
keeper.blur();
PAGE.focus();
console.log('整页跳转辅助窗口已启动；请保持它打开');
} catch (error) {
console.warn('整页跳转后无法自动重新启动脚本；请允许此站点打开弹出窗口，或在新页面重新粘贴脚本。', error);
}
}
function waitForCoursePage() {
let attempts = 0;
const maxAttempts = 20;
PAGE[BOOT_TIMER_KEY] = setInterval(() => {
if ($('#coursetree').length > 0) {
clearInterval(PAGE[BOOT_TIMER_KEY]);
PAGE[BOOT_TIMER_KEY] = null;
initializePlayer();
return;
}
attempts++;
if (attempts >= maxAttempts) {
clearInterval(PAGE[BOOT_TIMER_KEY]);
PAGE[BOOT_TIMER_KEY] = null;
console.error('%c脚本启动超时：未检测到课程目录（#coursetree）。请确认当前处于课程播放页。', 'color:#F44336;font-weight:bold');
}
}, 1000);
}
function attachQuizAutomation(app) {
const attemptedQuizzes = new Set();
const attemptedVideoQuizzes = new Set();
const videoQuizFailures = new Map();
const videoQuizStates = new Map();
const MAX_VIDEO_QUIZ_ATTEMPTS = 3;
let quizBusy = false;
let quizLoadRetries = 0;
let videoQuizBusy = false;
let videoQuizTimer = null;
let videoQuizRetryAt = 0;
let videoQuizSkipAt = 0;
let videoQuizStuckSince = 0;
let videoQuizDiagAt = 0;
let videoQuizContinueAt = 0;
let videoEndedNextTimer = 0;
let activeVideoQuiz = null;
let leaveDialogClickedAt = 0;
let leaveDialogSeenAt = 0;
let stopped = false;
const originalDestroy = app.destroy.bind(app);
app.destroy = function () {
stopped = true;
// 标记已销毁：销毁前排队的一次性定时器（重试播放、结束事件）即使触发也不再操作页面
app._destroyed = true;
clearInterval(videoQuizTimer);
originalDestroy();
};

const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const visible = (el) => Boolean(el && el.isConnected && el.getClientRects().length &&
el.ownerDocument.defaultView.getComputedStyle(el).visibility !== 'hidden');
const kindPattern = /[\[【](单选题|多选题|判断题)[\]】]/;

function courseDocuments() {
const result = [];
const visit = (doc, depth) => {
if (!doc || depth > 3 || result.includes(doc)) return;
result.push(doc);
for (const frame of doc.querySelectorAll('iframe')) {
try { visit(frame.contentDocument, depth + 1); } catch (_) { /* cross origin */ }
}
};
visit(document, 0);
return result;
}

function pageShowsNoContent() {
for (const doc of courseDocuments()) {
if (!doc.body) continue;
try {
const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
let node;
while ((node = walker.nextNode())) {
if (!/暂无内容|暂无学习内容|暂无任务点|暂无可学习内容/.test(clean(node.textContent))) continue;
if (visible(node.parentElement)) return true;
}
} catch (_) { /* 跨域或页面正在重建 */ }
}
return false;
}

app._pageShowsNoContent = pageShowsNoContent;

// 判断当前步骤不能只看 iframe 的 num：num 只是“第几个任务点”，不是步骤类型。
// 例如 1.2 学习天地有两个视频时，第二个视频同样是 num=1，旧逻辑却会当成章节测验。
// 这里叠加多个依据：有没有正在播放的视频、测验框架里是否真有题目、目录高亮的是不是测验节点。
let stepProbeAt = 0;
let stepProbeState = { videoAny: false, videoPlaying: false, quiz: 'none' };

function visibleVideoState() {
const state = { any: false, playing: false };
for (const doc of courseDocuments()) {
try {
for (const video of doc.querySelectorAll('video')) {
const rects = video.getClientRects();
if (!rects.length || rects[0].width < 80 || rects[0].height < 40) continue;
state.any = true;
try {
if (!video.paused && !video.ended) state.playing = true;
} catch (_) { /* 播放器状态暂时读不到 */ }
}
} catch (_) { /* 跨域或页面正在重建 */ }
}
return state;
}

function activeCatalogLabel() {
let el = null;
try { el = document.querySelector('.posCatalog_active'); } catch (_) { el = null; }
return el ? clean(el.textContent || el.innerText) : '';
}

const QUIZ_TEXT_PATTERN = /[\[【](单选题|多选题|判断题|填空题|简答题)[\]】]|共\s*\d+\s*题|题量\s*[:：]\s*\d+|开始(答题|测验|考试)|继续(答题|作答)/;
// 页面整体像不像测验：题干、题量、满分、交卷这类只有试卷页才有的字眼
const QUIZ_PAGE_PATTERN = /[\[【](单选题|多选题|判断题|填空题|简答题)[\]】]|共\s*\d+\s*题|题量\s*[:：]\s*\d+|满分\s*[:：]?\s*\d+|我的答案|参考答案|开始答题|继续答题|重新答题|交卷|提交试卷/;
// 注意：.mark_item 是“任务点”区块的样式，图文页里每个任务点都有一个，绝不能当作题目结构
const QUIZ_DOM_SELECTOR = '.TiMu,.questionLi,.subject,.question-item,.questionBox,.stem';

function quizFrameEvidence() {
let frame = null;
try {
frame = Array.from(document.querySelectorAll('iframe[src*="/knowledge/cards"]')).find((item) => {
try {
const rects = item.getClientRects();
if (!rects.length || rects[0].width < 60 || rects[0].height < 60) return false;
return new URL(item.getAttribute('src'), location.href).searchParams.get('num') === '1';
} catch (_) { return false; }
}) || null;
} catch (_) { frame = null; }
if (!frame) return 'none';
const docs = [];
let crossOrigin = false;
const collect = (doc, depth) => {
if (!doc || depth > 3) return;
docs.push(doc);
for (const child of doc.querySelectorAll('iframe')) {
try { collect(child.contentDocument, depth + 1); } catch (_) { crossOrigin = true; }
}
};
let frameDoc = null;
try {
frameDoc = frame.contentDocument;
} catch (_) {
frameDoc = null;
}
// 浏览器对跨域框架的 contentDocument 会返回 null，读不到内容
if (!frameDoc) return 'unknown';
try {
collect(frameDoc, 0);
} catch (_) {
return 'unknown';
}
let sawText = false;
let sawDom = false;
let videoInside = false;
for (const doc of docs) {
try {
if (!doc.body) continue;
if (QUIZ_TEXT_PATTERN.test(String(doc.body.textContent || ''))) sawText = true;
if (doc.querySelector(QUIZ_DOM_SELECTOR)) sawDom = true;
// 单个复选框/单选框可能只是普通控件，至少要有 2 个才算作答选项
if (!sawDom && doc.querySelectorAll('input[type="radio"],input[type="checkbox"]').length >= 2) sawDom = true;
for (const video of doc.querySelectorAll('video')) {
const rects = video.getClientRects();
if (rects.length && rects[0].width >= 80 && rects[0].height >= 40) {
videoInside = true;
break;
}
}
} catch (_) { /* 忽略单个框架读取失败 */ }
}
// 框架里放的是视频、又没有任何题目时，不可能是章节测验（num=1 只是第二个视频任务点）
if (videoInside && !sawText && !sawDom) return 'none';
if (sawText || sawDom) return 'quiz';
if (crossOrigin) return 'unknown';
return 'none';
}

// 页面内容本身是不是一份试卷：不看 iframe 的 num、不看 URL 规则，只看页面上有什么
function quizPageEvidence() {
let strong = false;
let sawInputs = false;
let textAll = '';
for (const doc of courseDocuments()) {
try {
const body = doc.body;
if (!body) continue;
let text = '';
try { text = String(body.innerText || body.textContent || ''); } catch (_) { text = ''; }
if (text) textAll += `${text.slice(0, 6000)}\n`;
if (doc.querySelector(QUIZ_DOM_SELECTOR)) strong = true;
if (doc.querySelectorAll('input[type="radio"],input[type="checkbox"]').length >= 2) sawInputs = true;
} catch (_) { /* 跨域或页面正在重建 */ }
}
if (QUIZ_PAGE_PATTERN.test(textAll)) strong = true;
if (sawInputs && /(单选题|多选题|判断题|题量|共\s*\d+\s*题|交卷)/.test(textAll)) strong = true;
if (strong) return true;
// 题目框架跨域读不到文字时，退一步看可见内容框架的地址（作业/考试页）
for (const frame of document.querySelectorAll('iframe[src]')) {
let rect = null;
try { rect = frame.getClientRects()[0]; } catch (_) {}
if (!rect || rect.width < 400 || rect.height < 250) continue;
let src = '';
try { src = frame.getAttribute('src') || ''; } catch (_) { src = ''; }
if (/(\/exam\/|reVersionTestStartNew|\/mooc2\/work|\/work\/doHomeWork|examId=|workId=)/i.test(src)) return true;
}
return false;
}

function stepProbe() {
if (Date.now() - stepProbeAt < 800) return stepProbeState;
stepProbeAt = Date.now();
const video = visibleVideoState();
stepProbeState = { videoAny: video.any, videoPlaying: video.playing, quiz: quizFrameEvidence(), quizPage: quizPageEvidence() };
return stepProbeState;
}

const originalStepTitle = app._currentStepTitle.bind(app);
app._currentStepTitle = function () {
const title = originalStepTitle();
const probe = stepProbe();
const label = activeCatalogLabel();
const labelSaysQuiz = /测验|考试|测试|答题/.test(label);
// 内容优先：页面上确实是一份试卷（题干、题量、交卷…），
// 不管入口叫什么名字、iframe 带不带 num，都按测验处理。
// 页面有可见视频时不抢，避免把“视频上的弹题”当成整章测验。
if (probe.quizPage && !probe.videoAny && !probe.videoPlaying) return '章节测验';
if (title !== '章节测验') return title;
// 1) 视频还在播：绝不可能是章节测验
if (probe.videoPlaying) return '视频';
// 2) 内容框架里确实是文章/图片、又没有真正的题目结构：这是阅读/图文任务点
if (!probe.videoAny) {
let docPage = false;
try { docPage = contentFrameDocs().length > 0; } catch (_) { docPage = false; }
if (docPage) return '';
}
// 3) 框架里明确没有题目：有视频按视频，没有视频就交给阅读/图文逻辑
if (probe.quiz === 'none') {
if (probe.videoAny) return '视频';
if (labelSaysQuiz) return title;
return '';
}
// 4) 框架跨域读不到：目录高亮不是测验时，不再当作测验
if (probe.quiz === 'unknown') {
if (!labelSaysQuiz && label) return probe.videoAny ? '视频' : '';
if (probe.videoAny && !labelSaysQuiz) return '视频';
return title;
}
// 5) 有题目痕迹，但目录高亮明确不是测验节点（例如 1.2 学习天地）：仍按视频处理
if (label && !labelSaysQuiz && probe.videoAny) return '视频';
return title;
};

function quizCompleted() {
const scoreShown = courseDocuments().some((doc) => {
const text = clean(doc.body?.innerText);
const hasGrade = /本次成绩\s*\d+(?:\.\d+)?\s*分/.test(text);
return hasGrade && (/章节测验\s*已完成/.test(text) || /我的答案\s*[:：]/.test(text));
});
if (scoreShown) return true;
// 非标准入口的作业/考试页：只要明确提示提交成功，也算完成
const submitted = courseDocuments().some((doc) => {
let text = '';
try { text = clean(doc.body?.innerText); } catch (_) { text = ''; }
return /提交成功|交卷成功|试卷已提交|作答已提交|提交试卷成功/.test(text);
});
if (submitted) return true;
const cardsFrame = Array.from(document.querySelectorAll('iframe[src*="/knowledge/cards"]'))
.find((frame) => frame.getClientRects().length > 0);
const isQuizFrame = cardsFrame && new URL(cardsFrame.getAttribute('src'), location.href).searchParams.get('num') === '1';
// 目录高亮节点本身就是测验时，图标才代表“测验已完成”；视频节点的完成图标不能算
const quizLabel = /测验|考试|测试|答题/.test(activeCatalogLabel());
return Boolean(isQuizFrame && quizLabel && document.querySelector('.posCatalog_active .icon_Completed'));
}

// —— 阅读/图文任务点：平台要求把内容区滚动到最底部才会记为完成 ——
// 一个节点里可能有多篇图文（num 0、1、2…），完成一篇后点“下一节”继续下一篇。
let docTaskBusy = false;
let docTaskWakeAt = 0;
let docTaskSignature = '';
let docTaskHandledAt = 0;
let docTaskNextAttempts = 0;

function contentFrameDocs() {
const items = [];
for (const doc of courseDocuments()) {
let frameEl = null;
try { frameEl = doc.defaultView && doc.defaultView.frameElement; } catch (_) { frameEl = null; }
// 只处理可见的内容框架，跳过顶层目录页和隐藏框架
if (!frameEl) continue;
let rect = null;
try { rect = frameEl.getClientRects()[0]; } catch (_) {}
if (!rect || rect.width < 200 || rect.height < 150) continue;
// 右侧的讨论/笔记/消息这类边栏框架也有正文，但绝不是任务点内容，不能去滚它
let frameSrc = '';
try { frameSrc = String(frameEl.getAttribute('src') || ''); } catch (_) { frameSrc = ''; }
const knownContent = /(\/knowledge\/cards|\/exam\/|reVersionTestStartNew|\/work\/)/i.test(frameSrc);
const sidePanel = /(discuss|note|chat|comment|reply|message|group|answer-card)/i.test(frameSrc);
const winWidth = window.innerWidth || 1280;
const inMainArea = rect.left < winWidth * 0.35 && rect.left + rect.width > winWidth * 0.3;
if (sidePanel && !knownContent) continue;
if (!knownContent && !inMainArea) continue;
let text = '';
let images = 0;
try { text = clean(doc.body ? doc.body.innerText : ''); } catch (_) { text = ''; }
try {
for (const img of doc.querySelectorAll('img')) {
const r = img.getClientRects()[0];
if (r && r.width >= 60 && r.height >= 40) images++;
}
} catch (_) {}
if (text.length < 30 && images === 0) continue;
// 空页面和测验框架都不按图文处理
if (/暂无内容|暂无学习内容|暂无任务点/.test(text) && text.length < 200) continue;
// 试卷页（题干/题量/满分/交卷）不管出现在哪个框架里，都不能当图文去滚
if (QUIZ_PAGE_PATTERN.test(text)) continue;
try { if (doc.querySelector(QUIZ_DOM_SELECTOR)) continue; } catch (_) {}
// 视频页（哪怕播放器还没渲染完）不按图文处理，交给视频逻辑
let hasVideo = false;
try {
hasVideo = Boolean(doc.querySelector('video,.vjs-tech,.vjs-big-play-button,#video_html5_api,.ans-video'));
} catch (_) { hasVideo = false; }
if (hasVideo) continue;
items.push({ doc, text, images });
}
return items;
}

function documentScrollables(docs) {
const list = [];
for (const item of docs) {
const doc = item.doc;
const win = doc.defaultView;
if (!win) continue;
const add = (el) => {
if (!el || list.some((entry) => entry.el === el)) return;
let r = null;
try { r = el.getClientRects()[0]; } catch (_) {}
if (r && (r.width < 140 || r.height < 70)) return;
list.push({ el, doc });
};
try {
const scroller = doc.scrollingElement || doc.documentElement;
if (scroller && scroller.scrollHeight - scroller.clientHeight > 40) add(scroller);
for (const el of doc.querySelectorAll('div,section,article,main')) {
if (list.length >= 12) break;
const style = win.getComputedStyle(el);
if (!/(auto|scroll|overlay)/.test(style.overflowY)) continue;
if (el.scrollHeight - el.clientHeight <= 40 || el.scrollHeight < 300) continue;
add(el);
}
} catch (_) { /* 忽略单个框架 */ }
}
return list;
}

function containerAtBottom(entry) {
try {
const max = Math.max(0, entry.el.scrollHeight - entry.el.clientHeight);
return max <= 20 || entry.el.scrollTop >= max - 6;
} catch (_) { return true; }
}

function cardsFrameSrcs() {
const srcs = [];
try {
for (const frame of document.querySelectorAll('iframe[src*="/knowledge/cards"]')) {
try {
if (!frame.getClientRects().length) continue;
srcs.push(frame.getAttribute('src') || '');
} catch (_) { /* 忽略单个框架 */ }
}
} catch (_) { /* 忽略整体失败 */ }
return srcs.join('||');
}

async function scrollToBottom(entry) {
const { el, doc } = entry;
const win = doc.defaultView;
if (!win) return;
const max = Math.max(0, el.scrollHeight - el.clientHeight);
if (max <= 20) return;
const isPageScroller = el === doc.scrollingElement || el === doc.documentElement || el === doc.body;
// 先把这一块内容滚进可视区，模拟“人先看到这一篇，再往下读”
if (!isPageScroller) {
try { el.scrollIntoView({ block: 'center' }); } catch (_) {}
await sleep(180);
}
// 分多步缓慢滚动，模拟真实阅读，触发平台（ed_complete.js）的滚动监听
const steps = Math.min(24, Math.max(8, Math.ceil(max / Math.max(200, el.clientHeight * 0.7))));
for (let i = 1; i <= steps; i++) {
if (stopped) return;
el.scrollTop = Math.round((max * i) / steps);
try { el.dispatchEvent(new win.Event('scroll', { bubbles: true })); } catch (_) {}
try { el.dispatchEvent(new win.WheelEvent('wheel', { deltaY: 320, bubbles: true, cancelable: true })); } catch (_) {}
// 外层阅读页的监听通常挂在 window 上，元素滚动后同步补一次
if (isPageScroller) {
try { win.scrollTo(0, el.scrollTop); } catch (_) {}
try { win.dispatchEvent(new win.Event('scroll')); } catch (_) {}
}
await sleep(220 + Math.floor(Math.random() * 160));
}
el.scrollTop = max;
try { el.dispatchEvent(new win.Event('scroll', { bubbles: true })); } catch (_) {}
if (isPageScroller) {
try { win.scrollTo(0, max); } catch (_) {}
try { win.dispatchEvent(new win.Event('scroll')); } catch (_) {}
}
}

// 一个任务点里可能叠着多篇图文：外层页面向下滚动 + 每篇自己的阅读器再滚动。
// 平台是按篇调用 completed(index) 的，所以必须把每个滚动区都推到底、并反复检查新渲染出来的图文。
async function readThroughDocuments() {
let rounds = 0;
let lastSignature = '';
let stableRounds = 0;
let sawCompletion = false;
let containers = 0;
while (rounds < 8 && !stopped) {
rounds++;
const docs = contentFrameDocs();
if (!docs.length) break;
const entries = documentScrollables(docs);
containers = Math.max(containers, entries.length);
const pending = rounds === 1 ? entries : entries.filter((entry) => !containerAtBottom(entry));
for (const entry of pending) {
if (stopped) break;
await scrollToBottom(entry);
}
// 每个内容页面本身也推到底，让折叠在下面的图文有机会渲染出来
for (const item of docs) {
if (stopped) break;
const doc = item.doc;
const win = doc.defaultView;
const scroller = doc.scrollingElement || doc.documentElement;
if (!win || !scroller) continue;
const max = Math.max(0, scroller.scrollHeight - scroller.clientHeight);
if (max <= 40 || scroller.scrollTop >= max - 6) continue;
scroller.scrollTop = max;
try { win.scrollTo(0, max); } catch (_) {}
try { scroller.dispatchEvent(new win.Event('scroll', { bubbles: true })); } catch (_) {}
try { win.dispatchEvent(new win.Event('scroll')); } catch (_) {}
try { scroller.dispatchEvent(new win.WheelEvent('wheel', { deltaY: 600, bubbles: true, cancelable: true })); } catch (_) {}
await sleep(500);
}
await sleep(600);
const after = documentScrollables(contentFrameDocs());
const allBottom = after.length > 0 && after.every(containerAtBottom);
if (documentCompletionShown()) sawCompletion = true;
const signature = after.map((entry) => `${entry.el.scrollTop}:${entry.el.scrollHeight}:${entry.el.clientHeight}`).join('|');
if (signature === lastSignature) stableRounds++; else stableRounds = 0;
lastSignature = signature;
console.log(`%c第 ${rounds} 轮阅读滚动：滚动区 ${after.length} 个，全部到底=${allBottom}，完成标记=${sawCompletion}`, 'color:#607D8B');
if (allBottom && (sawCompletion || stableRounds >= 2)) break;
if (stableRounds >= 3) break;
}
return { rounds, containers, sawCompletion };
}

async function nudgeToBottom(entry) {
const { el, doc } = entry;
const win = doc.defaultView;
if (!win) return;
const max = Math.max(0, el.scrollHeight - el.clientHeight);
if (max <= 20) return;
for (let i = 0; i < 3; i++) {
if (stopped) return;
el.scrollTop = Math.max(0, max - 120 - i * 40);
try { el.dispatchEvent(new win.Event('scroll', { bubbles: true })); } catch (_) {}
await sleep(160);
el.scrollTop = max;
try { el.dispatchEvent(new win.Event('scroll', { bubbles: true })); } catch (_) {}
await sleep(160);
}
}

function documentCompletionShown() {
try {
if (document.querySelector('.posCatalog_active .icon_Completed')) return true;
} catch (_) {}
for (const item of contentFrameDocs()) {
if (/任务点已完成|阅读已完成|已完成阅读|本篇已完成/.test(item.text)) return true;
}
return false;
}

async function waitForDocumentCompletion(ms) {
const until = Date.now() + ms;
while (Date.now() < until) {
if (stopped) return false;
if (documentCompletionShown()) return true;
await sleep(500);
}
return false;
}

// 当前页面是否还有“没播完的视频”：有就先把视频交给视频流程，视频播完再回到图文
function pageHasUnfinishedVideo() {
try {
if (typeof app._getVideoEl !== 'function') return visibleVideoState().any;
const video = app._getVideoEl();
if (!video) return false;
let visibleNow = false;
try {
visibleNow = typeof app._videoIsVisible === 'function' ? app._videoIsVisible(video) : video.getClientRects().length > 0;
} catch (_) { visibleNow = false; }
let playingNow = false;
try { playingNow = !video.paused && !video.ended; } catch (_) { playingNow = false; }
if (!visibleNow && !playingNow) return false;
if (typeof app._videoIsDone === 'function') return !app._videoIsDone(video);
return playingNow;
} catch (_) { return false; }
}

function pageHasDocumentTasks() {
try { return contentFrameDocs().length > 0; } catch (_) { return false; }
}

app._handleDocumentTask = async function () {
if (stopped || this._destroyed) return false;
if (docTaskBusy) {
// 滚动任务正在进行，避免重复触发；稍后再确认下一步（限制排队，避免定时器堆积）
if (!docTaskWakeAt || Date.now() - docTaskWakeAt > 3000) {
docTaskWakeAt = Date.now();
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 1500);
}
return true;
}
// 本页还有没播完的视频时不抢活，交给视频流程；视频播完会再回到这里
if (pageHasUnfinishedVideo()) return false;
if (this._isChapterTest()) return false;
const docs = contentFrameDocs();
if (!docs.length) return false;
const signature = docs.map((item) => `${String((item.doc.location && item.doc.location.href) || '').slice(0, 120)}|${item.text.slice(0, 80)}`).join('||');
const samePage = Boolean(signature && signature === docTaskSignature);
// 本页图文是否还有没滚到底的：有就继续读；都到底了说明已经读完，跳过重复滚动
const pendingScroll = samePage && documentScrollables(docs).some((entry) => !containerAtBottom(entry));
if (pendingScroll) {
if (Date.now() - docTaskHandledAt < 12000) return true;
if (docTaskNextAttempts >= 6) {
console.warn('%c同一篇图文已多次尝试仍未切换，已暂停自动推进，请手动检查', 'color:#FF9800');
return true;
}
docTaskNextAttempts++;
docTaskHandledAt = Date.now();
console.log('%c仍停留在同一篇图文，重新点击“下一节”', 'color:#FF9800');
setTimeout(() => { if (!stopped && !app._destroyed) app.nextUnit(); }, 600);
return true;
}
const alreadyRead = samePage && !pendingScroll;
docTaskBusy = true;
docTaskSignature = signature;
docTaskHandledAt = Date.now();
if (!alreadyRead) docTaskNextAttempts = 0;
this._isPlaying = false;
this._noVideoRetryTimes = 0;
this._clearCheckInterval();
const startFrameSrcs = cardsFrameSrcs();
try {
const totalChars = docs.reduce((sum, item) => sum + item.text.length, 0);
const totalImages = docs.reduce((sum, item) => sum + item.images, 0);
let read = { rounds: 0, containers: documentScrollables(docs).length, sawCompletion: documentCompletionShown() };
if (alreadyRead) {
console.log('%c本页图文已经滚动到底，跳过重复阅读，检查是否还有视频/下一步', 'color:#607D8B');
} else {
console.log(`%c检测到阅读/图文任务点（约 ${totalChars} 字，${totalImages} 张图），开始滚动到最底部`, 'color:#2196F3');
read = await readThroughDocuments();
if (!read.sawCompletion) {
console.log('%c暂未看到完成标记，在底部再轻微滚动一次以确保触发平台检测', 'color:#FF9800');
for (const entry of documentScrollables(contentFrameDocs())) {
if (stopped) return true;
await nudgeToBottom(entry);
}
read.sawCompletion = await waitForDocumentCompletion(3000);
}
if (read.sawCompletion) console.log(`%c阅读任务点已完成（共 ${read.rounds} 轮，覆盖 ${read.containers} 个滚动区），准备进入下一学习步骤`, 'color:#4CAF50');
else console.warn(`%c已滚动 ${read.rounds} 轮、覆盖 ${read.containers} 个滚动区，暂未收到平台完成标记，仍按已完成继续切换（若被弹窗拦下会自动处理）`, 'color:#FF9800');
}
docTaskHandledAt = Date.now();
} catch (error) {
console.warn('阅读任务点滚动失败，已跳过本次滚动:', error && error.message ? error.message : error);
} finally {
docTaskBusy = false;
}
// 有的课程在阅读完成后会自动切到下一步，这时不要再点“下一节”，否则会跳过内容
const endFrameSrcs = cardsFrameSrcs();
if (endFrameSrcs && startFrameSrcs && endFrameSrcs !== startFrameSrcs) {
console.log('%c页面已自动进入下一学习步骤', 'color:#4CAF50');
app._nextUnitPending = false;
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 600);
return true;
}
// 图文在前、视频在后（或中途穿插）时，读完别急着切走：先看看本页有没有渲染出来的视频
let pendingVideo = null;
try { pendingVideo = typeof app._nextPlayableVideo === 'function' ? app._nextPlayableVideo(null) : null; } catch (_) { pendingVideo = null; }
if (pendingVideo) {
console.log('%c阅读完成，本页还有待播放的视频，先播放视频', 'color:#4CAF50');
app._nextUnitPending = false;
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 800);
return true;
}
try {
console.log('%c阅读任务点处理完毕，点击“下一节”继续', 'color:#4CAF50');
await goToNextStep();
} catch (error) {
app._nextUnitPending = false;
console.warn('%c切换下一学习步骤失败，10 秒后重试：' + (error && error.message ? error.message : error), 'color:#FF9800');
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 10000);
}
return true;
};

app._pageHasDocumentTasks = pageHasDocumentTasks;

function letterOf(el) {
const text = clean(el.textContent).replace(/[.、．:：,，]+$/, '');
return /^[A-H]$/.test(text) ? text : '';
}

function stripOptionLetter(value, letter) {
return clean(value)
.replace(new RegExp(`^\\s*${letter}\\s*[.、．:：]?\\s*`), '')
.replace(/\s*提交(答案)?\s*$/, '')
.trim();
}

function trimToNextOption(text) {
const match = String(text || '').match(/(?<![A-Za-z])[A-H]\s*[.、．:：]\s*/);
return (match && match.index > 0 ? text.slice(0, match.index) : text).trim();
}

function optionElements(card) {
const labels = Array.from(card.querySelectorAll('span,div,label,li,p,b,i,strong,a'))
.filter((el) => letterOf(el) && !Array.from(el.children).some((child) => letterOf(child)));
const found = new Map();
for (const label of labels) {
const letter = letterOf(label);
if (found.has(letter)) continue;
let target = label;
for (let n = 0; n < 5; n++) {
const parent = target.parentElement;
if (!parent || parent === card) break;
const otherLetters = Array.from(parent.querySelectorAll('span,div,label,li,p,b,i,strong,a'))
.filter((el) => letterOf(el) && el !== label);
if (otherLetters.some((el) => !el.contains(label) && !label.contains(el))) break;
target = parent;
if (stripOptionLetter(target.innerText, letter)) break;
}
let text = stripOptionLetter(target.innerText, letter);
if (!text) {
let row = label.parentElement;
for (let n = 0; n < 3 && row && row !== card; n++) {
const rowText = trimToNextOption(stripOptionLetter(row.innerText, letter));
if (rowText) {
text = rowText;
const textEl = Array.from(row.querySelectorAll('span,div,label,li,p,b,i,strong,a'))
.find((el) => clean(el.innerText) === rowText && !el.contains(label) && !label.contains(el));
target = textEl || row;
break;
}
row = row.parentElement;
}
}
if (text) found.set(letter, { letter, text, element: target });
}
if (found.size >= 2) return Array.from(found.values()).sort((a, b) => a.letter.localeCompare(b.letter));
const inputs = Array.from(card.querySelectorAll('input[type="radio"],input[type="checkbox"]'));
if (inputs.length >= 2 && inputs.length <= 8) {
inputs.forEach((input, index) => {
let row = input.closest('label,li,tr') || input.parentElement || input;
for (let n = 0; n < 3 && row && row !== card; n++) {
if (clean(row.innerText).length > 1) break;
row = row.parentElement;
}
const rowText = clean(row?.innerText || '');
const match = rowText.match(/^([A-H])(?![A-Za-z])/);
const letter = match ? match[1] : String.fromCharCode(65 + index);
const text = trimToNextOption(stripOptionLetter(rowText, letter));
if (text && !found.has(letter)) found.set(letter, { letter, text, element: row });
});
}
return Array.from(found.values()).sort((a, b) => a.letter.localeCompare(b.letter));
}

function extractQuestions() {
const questions = [];
for (const doc of courseDocuments()) {
if (!doc.body) continue;
const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
const seenCards = new Set();
let node;
while ((node = walker.nextNode())) {
const kind = clean(node.textContent).match(kindPattern)?.[1];
if (!kind || !visible(node.parentElement)) continue;
let card = node.parentElement;
let options = [];
for (let depth = 0; card && depth < 9; depth++, card = card.parentElement) {
const cardText = clean(card.innerText);
const kinds = cardText.match(new RegExp(kindPattern.source, 'g')) || [];
if (kinds.length > 1) break;
options = optionElements(card);
if (options.length >= 2 && options.length <= 8) break;
}
if (!card || options.length < 2 || options.length > 8 || seenCards.has(card)) continue;
seenCards.add(card);
const full = card.innerText || '';
const firstOption = full.search(/(?:^|\n)\s*A\s*(?:[.、．]|\S)/);
const title = clean(firstOption >= 0 ? full.slice(0, firstOption) :
(node.parentElement.innerText || full))
.replace(/^\d+\s*/, '').replace(kindPattern, '').trim();
if (!title || title.length > 500 || options.some((option) => !option.text || option.text.length > 500)) continue;
questions.push({ kind, title, options, card, doc });
}
}
return questions;
}

function findButton(doc, label) {
const candidates = Array.from(doc.querySelectorAll('button,a,input[type="button"],input[type="submit"],[role="button"],div,span'))
.filter((el) => visible(el) && clean(el.value || el.innerText) === label);
return candidates.find((el) => /^(BUTTON|A|INPUT)$/.test(el.tagName)) ||
candidates.find((el) => !Array.from(el.children).some((child) => clean(child.innerText) === label)) || null;
}

// 不同课程/作业页的提交按钮叫法不一样，统一找一遍
const QUIZ_SUBMIT_LABELS = ['提交', '交卷', '提交答案', '提交试卷', '交卷并查看结果'];
function findQuizSubmit(doc) {
for (const label of QUIZ_SUBMIT_LABELS) {
const button = findButton(doc, label);
if (button) return button;
}
return null;
}

function findNextButton() {
for (const doc of courseDocuments()) {
const known = doc.querySelector('#prevNextFocusNext, #right1, .nextChapter');
if (visible(known) && clean(known.innerText || known.title).includes('下一节')) return known;
const generic = findButton(doc, '下一节');
if (generic) return generic;
}
return null;
}

function findLeaveChapterDialog() {
const marker = /当前章节还有任务点未完成|还有任务点未完成/;
for (const doc of courseDocuments()) {
if (!doc.body) continue;
if (!String(doc.body.textContent || '').includes('任务点未完成')) continue;
let walker;
try {
walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
} catch (_) { continue; }
let node;
while ((node = walker.nextNode())) {
if (!marker.test(clean(node.textContent))) continue;
let scope = node.parentElement;
let candidate = null;
for (let depth = 0; scope && depth < 8; depth++, scope = scope.parentElement) {
if (!visible(scope)) { candidate = null; break; }
const full = clean(scope.innerText);
if (full.length > 800) break;
if (!marker.test(full)) continue;
candidate = scope;
if (scope.querySelector('.layui-layer-btn0, .bluebtn, .sure, [role="dialog"] button') ||
findButtonIn(scope, '去完成') || findButtonIn(scope, '确定') || findButtonIn(scope, '确认')) break;
}
if (candidate) return candidate;
}
}
return null;
}

function findLeaveChapterDialogButton(dialog) {
for (const label of ['去完成', '去学习', '继续学习', '继续完成', '确定', '确认']) {
const button = findButtonIn(dialog, label);
if (button) return { button, label };
}
const primary = dialog.querySelector('.layui-layer-btn0, .bluebtn, .sure, [role="dialog"] button');
if (!visible(primary)) return null;
const text = clean(primary.value || primary.innerText || '').replace(/\s+/g, '');
if (/下一节|跳过|取消|关闭/.test(text)) return null;
return { button: primary, label: text || '主按钮' };
}

// 弹窗只有“下一节”时，用右上角关闭按钮取消本次跳节，既不跳过任务点也不会一直卡住
function findLeaveChapterDialogClose(dialog) {
for (const selector of ['.layui-layer-close', '.layui-layer-setwin a', '[aria-label*="关闭"]', '[title*="关闭"]', '[class*="close"]']) {
for (const el of dialog.querySelectorAll(selector)) {
if (!visible(el)) continue;
if (clean(el.innerText || '').length > 4) continue;
return el;
}
}
return null;
}

function confirmLeaveChapterDialog() {
if (Date.now() - leaveDialogClickedAt < 2000) return null;
const dialog = findLeaveChapterDialog();
if (!dialog) {
leaveDialogSeenAt = 0;
return null;
}
const found = findLeaveChapterDialogButton(dialog);
if (!found) {
if (!leaveDialogSeenAt) leaveDialogSeenAt = Date.now();
if (Date.now() - leaveDialogSeenAt < 3000) return null;
const closer = findLeaveChapterDialogClose(dialog);
if (!closer) return null;
leaveDialogClickedAt = Date.now();
leaveDialogSeenAt = 0;
console.warn('%c平台弹窗只有“下一节”，已点击右上角关闭取消本次跳节，继续完成本页剩余任务点', 'color:#FF9800');
closer.click();
if (typeof app !== 'undefined' && app && typeof app._resumeAfterTaskDialog === 'function') {
app._resumeAfterTaskDialog('关闭弹窗');
}
return '关闭弹窗';
}
leaveDialogSeenAt = 0;
leaveDialogClickedAt = Date.now();
console.log(`%c检测到“当前章节还有任务点未完成”弹窗，自动点击“${found.label}”去完成剩余任务点`, 'color:#FF9800');
found.button.scrollIntoView({ block: 'center' });
found.button.click();
if (typeof app !== 'undefined' && app && typeof app._resumeAfterTaskDialog === 'function') {
app._resumeAfterTaskDialog(found.label);
}
return found.label;
}

async function revealQuizQuestions() {
const docs = courseDocuments();
const submit = docs.map((doc) => findQuizSubmit(doc)).find(Boolean);
if (!submit) return;
let scroller = submit.parentElement;
while (scroller && scroller !== submit.ownerDocument.body) {
const style = scroller.ownerDocument.defaultView.getComputedStyle(scroller);
if (/(auto|scroll)/.test(style.overflowY) && scroller.scrollHeight > scroller.clientHeight + 100) break;
scroller = scroller.parentElement;
}
if (!scroller || scroller === submit.ownerDocument.body) {
scroller = submit.ownerDocument.scrollingElement;
}
if (!scroller || scroller.scrollHeight <= scroller.clientHeight + 100) return;
scroller.scrollTop = 0;
await sleep(150);
for (let step = 0; step < 50; step++) {
const bottom = scroller.scrollHeight - scroller.clientHeight;
if (scroller.scrollTop >= bottom - 2) break;
scroller.scrollTop = Math.min(bottom, scroller.scrollTop + Math.max(300, scroller.clientHeight * 0.75));
await sleep(120);
}
}

const QUIZ_START_LABELS = ['开始答题', '开始测验', '开始考试', '进入答题', '继续答题', '继续作答'];

async function waitForQuizQuestions() {
let submitDoc = null;
let startClicked = false;
for (let attempt = 0; attempt < 240; attempt++) {
if (stopped) throw new Error('脚本已停止');
if (quizCompleted()) return null;
submitDoc = courseDocuments().find((doc) => findQuizSubmit(doc));
if (submitDoc) break;
// 图文/阅读任务点被误判成测验时，不要干等 120 秒：8 秒后确认到正文就交回阅读流程
if (attempt >= 16 && attempt % 16 === 0) {
let docCount = 0;
try { docCount = contentFrameDocs().length; } catch (_) { docCount = 0; }
if (docCount) throw new Error('当前页面是阅读/图文任务点，不是章节测验');
}
// 有的章节测验先显示“开始答题/开始测验”入口，点了之后才加载题目
if (!startClicked) {
const start = courseDocuments()
.map((doc) => findTextControl(doc.documentElement, QUIZ_START_LABELS))
.find(Boolean);
if (start) {
startClicked = true;
console.log('%c检测到测验入口，点击“开始答题”', 'color:#2196F3');
fireClick(start);
await sleep(800);
continue;
}
}
if (attempt > 0 && attempt % 30 === 0) console.log(`测验提交按钮仍在加载，已等待 ${attempt / 2} 秒`);
await sleep(500);
}
if (!submitDoc) throw new Error('进入章节测验后等待 120 秒，仍未找到“提交”按钮。请检查题目框架是否正常加载');

await revealQuizQuestions();
let previousSignature = '';
let stableCount = 0;
for (let attempt = 0; attempt < 240; attempt++) {
if (stopped) throw new Error('脚本已停止');
if (quizCompleted()) return null;
const questions = extractQuestions();
const countText = clean(submitDoc.body.innerText).match(/题量\s*[:：]\s*(\d+)/);
const expected = countText ? Number(countText[1]) : null;
if (questions.length && (!expected || questions.length === expected)) {
const signature = questions.map((q) => `${q.kind}:${q.title}:${q.options.length}`).join('|');
stableCount = signature === previousSignature ? stableCount + 1 : 0;
previousSignature = signature;
if (stableCount >= 3) return questions;
} else {
stableCount = 0;
previousSignature = '';
}
if (attempt > 0 && attempt % 30 === 0) console.log(`测验题目仍在加载，已等待 ${attempt / 2} 秒；当前识别 ${questions.length} 道`);
await sleep(500);
}
throw new Error('测验框架已打开，但等待 120 秒仍未识别完整题目。可运行 app.inspectQuiz() 查看当前识别结果');
}

async function askDeepSeek(questions) {
const payload = questions.map((q, i) => ({
id: i + 1,
type: q.kind,
question: q.title,
options: q.options.map((o) => ({ letter: o.letter, text: o.text })),
}));
console.log('以下是本次发送给 DeepSeek 的题干和选项：', payload);
if (DIRECT_MODE) return PAGE.__deepseekAsk(payload);
let response;
try {
response = await fetch(`${LOCAL_URL}/answer`, {
method: 'POST',
headers: { 'Content-Type': 'application/json', 'X-Xuexitong-Token': LOCAL_TOKEN },
body: JSON.stringify({ questions: payload }),
signal: AbortSignal.timeout(900000),
});
} catch (error) {
throw new Error(`无法连接本地 DeepSeek 服务。请确认启动窗口仍在运行，且 Edge 允许本地网络访问。详情：${error.message}`);
}
const data = await response.json().catch(() => null);
if (!response.ok) throw new Error(data?.error || `本地 DeepSeek 服务返回 HTTP ${response.status}`);
return data.answers;
}

function validateAnswers(questions, answers) {
if (!Array.isArray(answers) || answers.length !== questions.length) throw new Error('AI 返回的题目数量不匹配');
const result = new Map();
for (const item of answers) {
if (!Number.isInteger(item.id) || result.has(item.id) || !Array.isArray(item.letters))
throw new Error('AI 答案格式错误');
const q = questions[item.id - 1];
if (!q) throw new Error('AI 返回未知题号');
const letters = item.letters.map((letter) => clean(letter).toUpperCase());
if (!letters.length) throw new Error(`第 ${item.id} 题 AI 未给出选项，已停止提交`);
if (new Set(letters).size !== letters.length) throw new Error(`第 ${item.id} 题答案包含重复选项，已停止提交`);
if (q.kind !== '多选题' && letters.length !== 1)
throw new Error(`第 ${item.id} 题是${q.kind}，但 AI 返回了 ${letters.length} 个选项，已停止提交`);
const invalidLetters = letters.filter((letter) => !q.options.some((option) => option.letter === letter));
if (invalidLetters.length)
throw new Error(`第 ${item.id} 题 AI 返回了页面中不存在的选项：${invalidLetters.join('、')}，已停止提交`);
result.set(item.id, letters);
}
return result;
}

async function selectAnswers(questions, answers) {
for (let i = 0; i < questions.length; i++) {
const q = questions[i];
for (const letter of answers.get(i + 1)) {
if (stopped) throw new Error('脚本已停止');
const option = q.options.find((item) => item.letter === letter);
if (!option?.element?.isConnected) throw new Error(`第 ${i + 1} 题选项已变化`);
const existingInput = option.element.matches('input') ? option.element : option.element.querySelector('input');
const alreadyChecked = Boolean(existingInput?.checked) ||
option.element.getAttribute('aria-checked') === 'true' ||
Boolean(option.element.querySelector('[aria-checked="true"], .checked, .selected, .is-checked, .checkbox-checked'));
if (alreadyChecked) continue;
option.element.scrollIntoView({ block: 'center' });
const before = q.card.outerHTML;
option.element.click();
await sleep(150);
let after = q.card.outerHTML;
let input = option.element.matches('input') ? option.element : option.element.querySelector('input');
let checked = Boolean(input?.checked || option.element.getAttribute('aria-checked') === 'true');
if (before === after && !checked) {
const fallbacks = [];
if (input) fallbacks.push(input);
const label = option.element.closest('label') || option.element.querySelector('label');
if (label && label !== option.element) fallbacks.push(label);
const letterEl = Array.from(option.element.querySelectorAll('*')).find((el) => letterOf(el) === letter);
if (letterEl) fallbacks.push(letterEl);
for (const el of fallbacks) {
el.click();
await sleep(150);
after = q.card.outerHTML;
const currentInput = el.matches('input') ? el : el.querySelector('input');
if (currentInput?.checked) {
input = currentInput;
checked = true;
break;
}
if (before !== after) {
checked = Boolean(el.getAttribute('aria-checked') === 'true');
break;
}
}
}
if (before === after && !checked) throw new Error(`第 ${i + 1} 题 ${letter} 选项未确认选中，已停止提交`);
}
}
}

async function confirmSubmitDialog() {
for (let i = 0; i < 20; i++) {
if (stopped) throw new Error('脚本已停止');
const dialogs = courseDocuments().flatMap((doc) =>
Array.from(doc.querySelectorAll('#popok,[role="dialog"],[role="alertdialog"],.layui-layer-dialog,.el-message-box,.modal')));
const platformButton = dialogs.find((el) => el.id === 'popok' && visible(el));
if (platformButton) {
const message = clean(platformButton.ownerDocument.querySelector('#popcontent')?.innerText);
if (/未作答|请选择|请作答|答完/.test(message) && !/确定提交|确认提交/.test(message))
throw new Error(`平台拒绝提交：${message}`);
console.log(`确认平台提交窗口：${message || '提交'}`);
platformButton.click();
return;
}
const dialog = dialogs.find((el) => el.id !== 'popok' && visible(el) && /提交|交卷/.test(clean(el.innerText)));
if (dialog) {
const confirm = findButton(dialog, '确定') || findButton(dialog, '确认') || findButton(dialog, '提交');
if (!confirm) throw new Error('提交确认窗口未找到确认按钮');
confirm.click();
return;
}
await sleep(250);
}
}

async function submitQuiz(doc) {
if (stopped) throw new Error('脚本已停止');
// 提交按钮可能在题干框架里，也可能在外层页面，两个地方都找
const submitDoc = findQuizSubmit(doc) ? doc : courseDocuments().find((item) => findQuizSubmit(item));
const submit = submitDoc ? findQuizSubmit(submitDoc) : null;
if (!submit) throw new Error('未找到测验提交按钮');
submit.scrollIntoView({ block: 'center' });
console.log('选项已选择，点击章节测验的提交按钮');
submit.click();
await confirmSubmitDialog();
console.log('提交已确认，等待学习通生成成绩或任务完成标记；确认后再点击“下一节”');
let elapsedHalfSeconds = 0;
while (!stopped) {
await sleep(500);
elapsedHalfSeconds++;
if (quizCompleted()) return;
// 提交后页面往往会直接切换，按钮消失说明已经交上去了，不用无限等成绩
if (elapsedHalfSeconds >= 20 && !findQuizSubmit(submitDoc)) {
console.log('%c提交按钮已消失，按“已提交”继续', 'color:#4CAF50');
return;
}
if (elapsedHalfSeconds >= 240) {
console.warn('%c等待成绩页超过 120 秒，按“已提交”继续，请稍后确认成绩是否生成', 'color:#FF9800');
return;
}
if (elapsedHalfSeconds % 30 === 0) console.log(`成绩页仍在加载，已等待 ${elapsedHalfSeconds / 2} 秒`);
}
throw new Error('脚本已停止');
}

async function goToNextStep() {
if (stopped) throw new Error('脚本已停止');
if (!findNextButton()) throw new Error('未找到页面下方的“下一节”按钮');
app._nextUnitPending = true;
const previousStep = app._currentStepTitle();
// 被“任务点未完成”弹窗退回时仍在原页面，需要恢复已完成视频标记，避免重播已经看完的段落
const previousDoneVideos = app._doneVideos;
const previousVideos = typeof app._findAllVideos === 'function' ? app._findAllVideos() : [];
const previousVideoSrcs = previousVideos.map((video) => {
try { return video.currentSrc || video.getAttribute('src') || ''; } catch (_) { return ''; }
});
// 阅读/图文任务点切换时页面里没有视频，靠内容框架的 src（num/chapterId 变化）判断是否已切换
const previousFrameSrcs = cardsFrameSrcs();
app._clearCheckInterval();
app._videoEl = null;
app._quizVideo = null;
app._doneVideos = new Map();
app._isPlaying = false;
let skipped = 0;
let emptySince = 0;
let clickedAt = 0;
let nextLogAt = 0;
const clickNext = async () => {
let button = findNextButton();
for (let retry = 0; !button && retry < 6 && !stopped; retry++) {
await sleep(500);
button = findNextButton();
}
if (!button) return false;
button.scrollIntoView({ block: 'center' });
button.click();
clickedAt = Date.now();
nextLogAt = clickedAt + 15000;
emptySince = 0;
return true;
};
console.log(`${previousStep || '当前学习步骤'}完成，点击页面“下一节”，等待新内容加载`);
if (!await clickNext()) throw new Error('未找到页面下方的“下一节”按钮');
let currentStep = previousStep;
let stepReady = false;
for (let attempt = 0; attempt < 600; attempt++) {
if (stopped) throw new Error('脚本已停止');
await sleep(500);
if (!app._nextUnitPending) return;
const dialogAction = confirmLeaveChapterDialog();
if (dialogAction) {
app._nextUnitPending = false;
app._doneVideos = previousDoneVideos;
console.log(`%c平台提示本章还有任务点未完成，已点击“${dialogAction}”，取消切换下一节，回到本页继续完成`);
return;
}
currentStep = app._currentStepTitle();
if (currentStep === '章节测验' && currentStep !== previousStep) {
stepReady = true;
break;
}
const frameSrcs = cardsFrameSrcs();
if (frameSrcs && previousFrameSrcs && frameSrcs !== previousFrameSrcs) {
stepReady = true;
break;
}
let videos = [];
try { videos = app._findAllVideos(); } catch (_) { videos = []; }
const videoLoaded = videos.some((item) => {
let src = '';
try { src = item.currentSrc || item.getAttribute('src') || ''; } catch (_) {}
const oldIndex = previousVideos.indexOf(item);
if (oldIndex === -1) return true;
const oldSrc = previousVideoSrcs[oldIndex];
if (!oldSrc) return false;
return Boolean(src) && src !== oldSrc;
});
if (videoLoaded) {
stepReady = true;
break;
}
if (pageShowsNoContent()) {
if (!emptySince) emptySince = Date.now();
} else {
emptySince = 0;
}
const waited = Date.now() - clickedAt;
const emptyFor = emptySince ? Date.now() - emptySince : 0;
const emptyConfirmed = emptyFor >= 6000 || (currentStep === '视频' && !videos.length && waited >= 45000);
if (emptyConfirmed) {
if (skipped >= 10) throw new Error('连续跳过 10 个“暂无内容”小节后仍未找到可学习内容，已停止，请手动检查');
skipped++;
console.warn(`%c当前小节${emptyFor >= 6000 ? '显示“暂无内容”' : '长时间未加载出视频'}，自动点击“下一节”跳过（第 ${skipped} 次）`, 'color:#FF9800');
if (!await clickNext()) throw new Error('未找到页面下方的“下一节”按钮');
currentStep = app._currentStepTitle();
continue;
}
if (waited >= 120000) {
throw new Error(`点击“下一节”后等待 120 秒，新学习步骤仍未加载完成；当前页签：${currentStep || '未显示'}`);
}
if (Date.now() >= nextLogAt) {
nextLogAt = Date.now() + 15000;
console.log(`下一学习步骤仍在加载，已等待 ${Math.round(waited / 1000)} 秒；当前页签：${currentStep || '未显示'}`);
}
}
if (!stepReady) throw new Error(`点击“下一节”后等待超时，新学习步骤仍未加载完成；当前页签：${currentStep || '未显示'}`);
app._nextUnitPending = false;
app._videoEl = null;
app._quizVideo = null;
app._doneVideos = new Map();
app._videoNextChecks = 0;
app._initCellData();
app.play();
}

app.nextUnit = function () {
if (stopped || this._nextUnitPending) return;
this._nextUnitPending = true;
goToNextStep().catch((error) => {
this._nextUnitPending = false;
console.error('切换下一学习步骤失败:', error);
});
};

app.inspectQuiz = function () {
return extractQuestions().map((q, i) => ({
id: i + 1, type: q.kind, question: q.title,
options: q.options.map((o) => `${o.letter}. ${o.text}`),
}));
};

// 诊断用：列出页面里所有视频（包括隐藏的）和所在框架，便于排查多视频页面
app.inspectVideos = function () {
const rows = [];
const docs = [];
const visit = (doc, depth) => {
if (!doc || depth > 4 || docs.includes(doc)) return;
docs.push(doc);
try {
for (const video of doc.querySelectorAll('video')) {
let rect = null;
try { rect = video.getClientRects()[0]; } catch (_) {}
rows.push({
frame: String((doc.location && doc.location.href) || '').slice(0, 90),
id: video.id || '',
src: String(video.currentSrc || video.getAttribute('src') || '').slice(0, 90),
visible: Boolean(rect),
size: rect ? `${Math.round(rect.width)}x${Math.round(rect.height)}` : '0x0',
ended: video.ended,
time: Math.round(video.currentTime || 0),
duration: Math.round(video.duration || 0),
});
}
} catch (_) {}
try {
for (const frame of doc.querySelectorAll('iframe')) {
let child = null;
try { child = frame.contentDocument; } catch (_) {}
if (child) visit(child, depth + 1);
}
} catch (_) {}
};
visit(document, 0);
const result = {
step: app._currentStepTitle(),
playable: app._findAllVideos().length,
videos: rows,
};
console.log('视频诊断结果（请把这一条展开后截图）：', result);
return result;
};

app._advanceChapterTest = function () {
if (stopped || quizBusy) return;
quizBusy = true;
(async () => {
if (quizCompleted()) {
console.log('检测到当前章节测验已完成，点击“下一节”进入新视频');
await goToNextStep();
return;
}
const entryProbe = stepProbe();
console.log('章节测验判定依据:', {
页签: app._currentStepTitle(),
目录高亮: activeCatalogLabel() || '未识别',
可见视频: entryProbe.videoAny,
视频播放中: entryProbe.videoPlaying,
测验框架: entryProbe.quiz,
试卷内容: entryProbe.quizPage,
});
console.log('已进入章节测验，等待题目和提交按钮加载');
let questions;
try {
questions = await waitForQuizQuestions();
} catch (error) {
if (stopped) return;
// 没等到测验内容时先复查步骤：平台经常把空白/预加载的测验框架留在页面上，
// 此时页面其实还在视频上，直接回到视频流程，不要整段脚本卡死。
if (app._currentStepTitle() !== '章节测验') {
console.warn(`%c没有进入真正的章节测验（${error.message}），已回到视频流程继续`, 'color:#FF9800');
app._nextUnitPending = false;
app._quizVideo = null;
app._videoEl = null;
app._isPlaying = false;
app._videoNextChecks = 0;
app._allDoneChecks = 0;
if (typeof app._clearCheckInterval === 'function') app._clearCheckInterval();
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 1200);
return;
}
// 确实停在测验页，但题目一直没出现：稍后重试几次，仍然不行就安静停下（不再抛错终止脚本）
if (quizLoadRetries < 3) {
quizLoadRetries++;
console.warn(`%c章节测验内容仍未加载出来（第 ${quizLoadRetries}/3 次重试，30 秒后再试）`, 'color:#FF9800');
setTimeout(() => { if (!stopped && !app._destroyed) app._advanceChapterTest(); }, 30000);
return;
}
console.error('章节测验自动作答停止:', error);
console.warn('%c自动答题已暂停，但脚本本身仍在运行；手动完成本章测验后可执行 app.nextUnit() 继续', 'color:#FF9800');
return;
}
quizLoadRetries = 0;
if (questions === null) {
console.log('检测到当前章节测验已完成，点击“下一节”进入新视频');
await goToNextStep();
return;
}
if (questions.length > 30) throw new Error('题目数量超过 30，已停止自动提交');
const docs = new Set(questions.map((q) => q.doc));
if (docs.size !== 1) throw new Error('题目跨多个框架，已停止自动提交');
const countText = clean(questions[0].doc.body.innerText).match(/题量\s*[:：]\s*(\d+)/);
if (countText && Number(countText[1]) !== questions.length)
throw new Error(`页面显示 ${countText[1]} 道题，脚本只识别 ${questions.length} 道，已停止提交`);
const signature = questions.map((q) => `${q.kind}:${q.title}`).join('|');
if (attemptedQuizzes.has(signature)) throw new Error('本次测验已尝试过，已停止重复提交');
console.log(`识别到 ${questions.length} 道题，正在调用 DeepSeek`);
const answers = validateAnswers(questions, await askDeepSeek(questions));
console.table(questions.map((q, i) => ({ 题号: i + 1, 题型: q.kind, 选择: answers.get(i + 1).join('') })));
await selectAnswers(questions, answers);
attemptedQuizzes.add(signature);
await submitQuiz(questions[0].doc);
console.log('章节测验提交已确认，点击“下一节”进入新视频');
quizBusy = false;
await goToNextStep();
})().catch((error) => {
app._nextUnitPending = false;
console.error('章节测验自动作答停止:', error);
})
.finally(() => { quizBusy = false; });
};

function videoQuizDocuments() {
const docs = [];
const add = (doc) => {
if (doc && !docs.includes(doc)) docs.push(doc);
};
const visit = (doc, depth) => {
if (!doc || depth > 3 || docs.includes(doc)) return;
add(doc);
let frames = [];
try { frames = Array.from(doc.querySelectorAll('iframe')); } catch (_) { return; }
for (const frame of frames) {
try { visit(frame.contentDocument, depth + 1); } catch (_) { /* 跨域 */ }
}
};
const video = typeof app._getVideoEl === 'function' ? app._getVideoEl() : null;
if (video && video.ownerDocument) visit(video.ownerDocument, 0);
for (const doc of courseDocuments()) visit(doc, 0);
visit(document, 0);
return docs;
}

function textSubmitCandidates(doc) {
const result = [];
if (!doc || !doc.body) return result;
try {
const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
let node;
while ((node = walker.nextNode())) {
const text = clean(node.textContent);
if (text !== '提交' && text !== '提交答案') continue;
const el = node.parentElement;
if (el && visible(el)) result.push(el);
}
} catch (_) { /* 跨域或页面正在重建 */ }
for (const el of doc.querySelectorAll('button,input[type="button"],input[type="submit"],[role="button"]')) {
const text = clean(el.value || el.innerText);
if ((text === '提交' || text === '提交答案') && visible(el) && !result.includes(el)) result.push(el);
}
return result;
}

function looksLikeVideoQuestion(text, options) {
if (!options || options.length < 2 || options.length > 8) return false;
return text.length >= 6 && options.every((option) => option.text && option.text.length <= 500);
}

function findButtonIn(card, label) {
// 平台按钮文字可能带空格、换行或多个图标子节点，按去掉空白后的文字比较更稳
const compact = (value) => clean(value).replace(/\s+/g, '');
const target = compact(label);
const candidates = Array.from(card.querySelectorAll('button,a,input[type="button"],input[type="submit"],[role="button"],div,span'))
.filter((el) => visible(el) && compact(el.value || el.innerText) === target);
return candidates.find((el) => /^(BUTTON|A|INPUT)$/.test(el.tagName)) ||
candidates.find((el) => !Array.from(el.children).some((child) => compact(child.innerText) === target)) || null;
}

const CONTINUE_LABELS = ['继续学习', '继续播放', '继续观看', '继续'];
const DISMISS_LABELS = [...CONTINUE_LABELS, '下一题', '知道了', '关闭', '确定'];

function controlText(el) {
try { return clean(el.value || el.innerText || el.textContent || ''); } catch (_) { return ''; }
}

// 按文字找按钮：允许按钮带图标或多余空格（innerText 不再严格等于标签），并优先取最内层元素
function findTextControl(root, labels) {
if (!root || typeof root.querySelectorAll !== 'function') return null;
const nodes = Array.from(root.querySelectorAll('button,a,input[type="button"],input[type="submit"],[role="button"],div,span,p,li'));
const found = [];
for (const el of nodes) {
if (!visible(el)) continue;
const text = controlText(el);
if (!text || text.length > 18) continue;
const label = labels.find((item) => text.length <= item.length + 4 && text.includes(item));
if (!label) continue;
const childSame = Array.from(el.children).some((child) => controlText(child) === text);
const rank = /^(BUTTON|A|INPUT)$/.test(el.tagName) ? 0 : el.getAttribute('role') === 'button' ? 1 : 2;
found.push({ el, text, childSame, rank });
}
if (!found.length) return null;
found.sort((a, b) => Number(a.childSame) - Number(b.childSame) || a.rank - b.rank || a.text.length - b.text.length);
return found[0].el;
}

// 用完整的鼠标事件序列点击，兼容只监听 mousedown/pointerdown 的播放器按钮
function fireClick(el) {
if (!el) return false;
const doc = el.ownerDocument || document;
const win = doc.defaultView || window;
try { el.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (_) { /* 忽略 */ }
let rect = { left: 0, top: 0, width: 0, height: 0 };
try { rect = el.getBoundingClientRect(); } catch (_) { /* 忽略 */ }
const options = {
bubbles: true,
cancelable: true,
composed: true,
view: win,
button: 0,
clientX: rect.left + rect.width / 2,
clientY: rect.top + rect.height / 2,
};
const dispatch = (type, Ctor) => {
try { el.dispatchEvent(new Ctor(type, options)); } catch (_) { /* 忽略单个事件失败 */ }
};
const Pointer = typeof win.PointerEvent === 'function' ? win.PointerEvent : win.MouseEvent;
dispatch('pointerover', Pointer);
dispatch('pointerdown', Pointer);
dispatch('mousedown', win.MouseEvent);
dispatch('pointerup', Pointer);
dispatch('mouseup', win.MouseEvent);
try {
if (typeof el.click === 'function') el.click();
else el.dispatchEvent(new win.MouseEvent('click', options));
} catch (_) { /* 忽略 */ }
return true;
}

function parseTextOptions(card) {
const lines = String(card.innerText || '').split(/\n+/).map(clean).filter(Boolean);
const parsed = [];
for (let i = 0; i < lines.length; i++) {
const match = lines[i].match(/^([A-H])\s*[.、．:：]?\s*(.*)$/);
if (!match || parsed.some((item) => item.letter === match[1])) continue;
let text = match[2].trim();
if (!text) {
const next = lines[i + 1] || '';
if (next && !/^[A-H](?:\s*[.、．:：]|\s|$)/.test(next) && next !== '提交' && next !== '提交答案') text = next;
}
if (text) parsed.push({ letter: match[1], text });
}
const found = [];
const nodes = Array.from(card.querySelectorAll('span,div,label,li,p,b,i,strong,a')).filter(visible);
for (const option of parsed) {
const escaped = option.text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const linePattern = new RegExp(`^\\s*${option.letter}\\s*[.、．:：]?\\s*${escaped}\\s*$`);
const element = nodes.find((el) => linePattern.test(clean(el.innerText))) ||
nodes.find((el) => clean(el.innerText) === option.text) ||
nodes.find((el) => clean(el.innerText) === option.letter);
if (element) found.push({ letter: option.letter, text: option.text, element });
}
return found.sort((a, b) => a.letter.localeCompare(b.letter));
}

function buildVideoQuestion(card, doc, options) {
const full = card.innerText || '';
const parsed = parseTextOptions(card);
if (parsed.length >= 2 && parsed.length <= 8) {
options = parsed;
} else if (!Array.isArray(options) || options.length < 2) {
options = parsed;
}
if (options.length < 2 || options.length > 8) return null;
if (options.some((option) => !option.element)) return null;
let kind = '';
if (/多选题/.test(full)) kind = '多选题';
else if (/单选题/.test(full)) kind = '单选题';
else if (/判断题/.test(full) || options.every((option) => /^(对|错|正确|错误|是|否)$/.test(option.text))) kind = '判断题';
else kind = '单选题';
let firstOption = full.search(/(?:^|\n)\s*A\s*(?:[.、．]|\s|\S)/);
if (firstOption < 0) firstOption = full.search(/A\s*[.、．]\s*|A\s+(?:对|错|正确|错误)/);
let title = clean(firstOption >= 0 ? full.slice(0, firstOption) : full)
.replace(/共\s*\d+\s*题[，,]?\s*(?:已答对\s*\d+\s*题?)?/g, ' ')
.replace(/^(单选题|多选题|判断题)\s*/, '')
.replace(/\s*(单选题|多选题|判断题)\s*$/, '')
.trim();
if (!title) title = kind;
if (title.length > 500) title = title.slice(0, 500);
options = options.map((option) => ({ ...option, text: option.text.length > 500 ? option.text.slice(0, 500) : option.text }));
return { kind, title, options, card, doc };
}

function findVideoQuizCard() {
for (const doc of videoQuizDocuments()) {
for (const button of textSubmitCandidates(doc)) {
let card = button.parentElement;
for (let depth = 0; card && depth < 10 && card !== doc.body; depth++, card = card.parentElement) {
const text = clean(card.innerText);
if (text.length > 3000) break;
if (text.length < 6) continue;
const options = optionElements(card);
if (!looksLikeVideoQuestion(text, options)) continue;
const question = buildVideoQuestion(card, doc, options);
if (question) return question;
}
}
}
return null;
}

async function confirmVideoQuizSubmit(card) {
for (let i = 0; i < 8; i++) {
await sleep(250);
if (stopped) return;
const dialogs = courseDocuments().flatMap((doc) =>
Array.from(doc.querySelectorAll('#popok,[role="dialog"],[role="alertdialog"],.layui-layer-dialog,.el-message-box,.modal')));
const popok = dialogs.find((el) => el.id === 'popok' && visible(el));
if (popok) {
popok.click();
return;
}
const dialog = dialogs.find((el) => visible(el) && !card.contains(el) && /确定提交|确认提交/.test(clean(el.innerText)));
if (dialog) {
const confirm = findButton(dialog, '确定') || findButton(dialog, '确认');
if (confirm) {
confirm.click();
return;
}
}
}
}

function videoQuizState(signature) {
if (!videoQuizStates.has(signature)) {
videoQuizStates.set(signature, {
signature,
question: null,
attempts: 0,
tried: [],
correctBefore: -1,
lastSubmittedAt: 0,
skipCount: 0,
gaveUp: false,
loggedUnknown: false,
});
}
return videoQuizStates.get(signature);
}

function videoQuizMaxAttempts(question) {
const count = question && Array.isArray(question.options) ? question.options.length : 0;
return Math.max(MAX_VIDEO_QUIZ_ATTEMPTS, Math.min(8, count + 1));
}

function findVisibleVideoQuizResult() {
for (const doc of videoQuizDocuments()) {
if (!doc.body) continue;
const bodyText = String(doc.body.textContent || '');
if (!/回答错误|答错了|答错啦|答案错误|回答不正确|不完全正确|真遗憾|很遗憾|再接再厉|您的回答正确|回答正确|答案正确|答对了/.test(bodyText)) continue;
let walker;
try {
walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
} catch (_) { continue; }
let node;
while ((node = walker.nextNode())) {
const text = clean(node.textContent);
if (!isVideoQuizWrong(text) && !isVideoQuizSuccess(text)) continue;
let scope = node.parentElement;
let picked = null;
for (let depth = 0; scope && depth < 6; depth++, scope = scope.parentElement) {
if (!visible(scope)) { picked = null; break; }
if (clean(scope.innerText).length > 1500) break;
if (!picked) picked = scope;
}
if (picked) return { card: picked, wrong: isVideoQuizWrong(text), success: isVideoQuizSuccess(text) };
}
}
return null;
}

function skipVideoQuizToNext(reason) {
if (Date.now() - videoQuizSkipAt < 5000) return false;
if (videoQuizSuccessVisible()) {
clickVideoQuizContinue();
console.log('%c弹题已答对，改为点击“继续学习”，不点“下一节”', 'color:#4CAF50');
return false;
}
const button = findNextButton();
if (!button) {
console.warn(`%c视频弹题${reason}，但页面上没有“下一节”按钮，请手动完成`, 'color:#F44336');
return false;
}
app._quizSkipAttempts = (app._quizSkipAttempts || 0) + 1;
if (app._quizSkipAttempts > 2) {
console.warn('%c视频弹题多次未通过、且已两次尝试跳过，为避免反复触发“任务点未完成”弹窗，已暂停自动跳节，请手动完成本题', 'color:#F44336;font-weight:bold');
return false;
}
videoQuizSkipAt = Date.now();
videoQuizStuckSince = 0;
app._videoQuizPending = false;
app._videoEndedDuringQuiz = false;
app._quizVideo = null;
console.warn(`%c视频弹题${reason}，自动点击“下一节”继续`, 'color:#FF9800');
button.scrollIntoView({ block: 'center' });
button.click();
return true;
}

function correctCount(text) {
const match = String(text || '').match(/已答对\s*(\d+)\s*题/);
return match ? Number(match[1]) : -1;
}

function isVideoQuizSuccess(text) {
return /您的回答正确|回答正确[！!。\s]|回答正确$|答案正确[！!。\s]|答案正确$|答对了[！!。\s]|答对了$|答对啦|全部正确|完全正确|太棒了|恭喜你|恭喜答对|恭喜.*正确/.test(text);
}

function isVideoQuizWrong(text) {
return /回答错误|答错了|答错啦|答案错误|回答不正确|不完全正确|真遗憾|很遗憾|再接再厉|不对哦|差一点|再想想|未答对|没答对|答得不对|请重新作答|重新作答|再试一次|重新回答|再次作答/.test(text);
}

function videoQuizQuizText(doc) {
try { return String(doc.body?.textContent || ''); } catch (_) { return ''; }
}

// 播放器内的“继续学习”按钮只要可见，就说明这轮弹题已经通过
function findVideoQuizContinueButton() {
const video = typeof app._getVideoEl === 'function' ? app._getVideoEl() : null;
const videoDoc = video && video.ownerDocument;
if (videoDoc) {
const inVideo = findTextControl(videoDoc, CONTINUE_LABELS);
if (inVideo) return inVideo;
}
for (const doc of videoQuizDocuments()) {
if (!doc.documentElement || doc === videoDoc) continue;
if (!/(共\s*\d+\s*题|已答对\s*\d+\s*题|回答正确|答对了|恭喜你)/.test(videoQuizQuizText(doc))) continue;
const button = findTextControl(doc, CONTINUE_LABELS);
if (button) return button;
}
return null;
}

function videoQuizBodyFeedback() {
const video = typeof app._getVideoEl === 'function' ? app._getVideoEl() : null;
const doc = video && video.ownerDocument;
const text = String(doc && doc.body ? doc.body.textContent || '' : '');
return {
success: /回答正确|答案正确|答对了|答对啦|全部正确|完全正确|太棒了|恭喜你|恭喜答对/.test(text),
wrong: /回答错误|答错了|答错啦|答案错误|回答不正确|不完全正确|真遗憾|很遗憾|再接再厉|未答对|没答对|答得不对/.test(text),
};
}

function videoQuizSuccessVisible() {
const feedback = videoQuizBodyFeedback();
// 页面明确显示答错、又没有答对文字时，一律按“未通过”处理。
// 否则答错后选项还没清空、面板仍停在原题时，会被误判成已通过而不再重答。
if (feedback.wrong && !feedback.success) return false;
const result = findVisibleVideoQuizResult();
if (result && result.success) return true;
if (feedback.wrong || !feedback.success) return false;
return Boolean(findVideoQuizContinueButton());
}

function clickVideoQuizContinue() {
if (Date.now() - videoQuizContinueAt < 2000) return false;
const button = findVideoQuizContinueButton();
if (!button) return false;
videoQuizContinueAt = Date.now();
app._videoQuizPending = false;
app._quizSkipAttempts = 0;
console.log('%c视频弹题已通过，自动点击“继续学习”', 'color:#4CAF50');
fireClick(button);
if (app._videoEndedDuringQuiz) scheduleVideoEndedNext(1500);
return true;
}

function scheduleVideoEndedNext(delay, attempt = 0) {
if (videoEndedNextTimer) clearTimeout(videoEndedNextTimer);
videoEndedNextTimer = setTimeout(() => {
videoEndedNextTimer = 0;
if (stopped || !app._videoEndedDuringQuiz) return;
if (app._videoQuizActive || app._videoQuizPending) {
scheduleVideoEndedNext(2000, attempt);
return;
}
if (findVideoQuizCard() || videoQuizSuccessVisible()) {
scheduleVideoEndedNext(2000, attempt);
return;
}
if (attempt < 2) {
scheduleVideoEndedNext(2000, attempt + 1);
return;
}
app._videoEndedDuringQuiz = false;
const endedDuringQuiz = app._endedVideoDuringQuiz || app._videoEl;
app._endedVideoDuringQuiz = null;
if (typeof app._proceedAfterVideo === 'function') {
app._proceedAfterVideo('视频弹题已处理完', endedDuringQuiz);
return;
}
console.log('%c视频弹题已处理完，继续切换下一节', 'color:#2196F3');
if (typeof app.nextUnit === 'function') app.nextUnit();
}, delay);
}
app._scheduleVideoEndedNext = scheduleVideoEndedNext;

const RETRY_LABELS = ['重新回答', '重新作答', '重新答题', '再次作答', '再试一次', '重新选择', '重试', '继续作答', '重做'];

function findRetryButton(card) {
for (let scope = card, depth = 0; scope && depth < 3; depth++, scope = scope.parentElement) {
const button = findTextControl(scope, RETRY_LABELS);
if (button) return button;
}
return null;
}

function dismissVideoQuiz(card) {
for (let scope = card, depth = 0; scope && depth < 4; depth++, scope = scope.parentElement) {
const button = findTextControl(scope, DISMISS_LABELS);
if (button) {
fireClick(button);
return true;
}
}
const globalButton = findVideoQuizContinueButton();
if (globalButton) {
fireClick(globalButton);
return true;
}
const doc = card.ownerDocument;
if (doc && doc.documentElement) {
const button = findTextControl(doc.documentElement, CONTINUE_LABELS);
if (button) {
fireClick(button);
return true;
}
}
return false;
}

function sameLetters(a, b) {
return [...a].sort().join('') === [...b].sort().join('');
}

function shownCorrectLetters(text) {
const match = String(text || '').match(/正确答案\s*[：:]\s*([A-H](?:\s*[、,，]?\s*[A-H])*)/);
if (!match) return null;
const letters = Array.from(new Set(match[1].match(/[A-H]/g) || []));
return letters.length ? letters : null;
}

function fallbackLetters(question, state) {
const tried = new Set(state.tried.flat());
const untried = question.options.map((option) => option.letter).filter((letter) => !tried.has(letter));
if (!untried.length) return null;
return question.kind === '多选题' ? untried : [untried[0]];
}

function videoQuizFeedbackText(text) {
const match = String(text || '').match(/(真遗憾[^。！!\n]*|很遗憾[^。！!\n]*|再接再厉[^。！!\n]*|回答错误[^。！!\n]*|答错了[^。！!\n]*|答案错误[^。！!\n]*|不完全正确[^。！!\n]*|未答对[^。！!\n]*|没答对[^。！!\n]*)/);
return match ? clean(match[1]) : '';
}

async function chooseVideoQuizLetters(question, state, shownLetters, feedbackText) {
if (shownLetters && shownLetters.length && shownLetters.every((letter) => question.options.some((option) => option.letter === letter))) {
const letters = question.kind === '多选题' ? shownLetters : [shownLetters[0]];
console.log(`%c使用页面提示的正确答案：${letters.join('')}`, 'color:#4CAF50');
return letters;
}
const tried = state.tried.filter((entry) => Array.isArray(entry) && entry.length);
if (!tried.length) {
const answers = validateAnswers([question], await askDeepSeek([question]));
return answers.get(1);
}
const triedText = tried.map((entry) => entry.join('、')).join('；');
const feedback = videoQuizFeedbackText(feedbackText);
const feedbackHint = feedback ? `页面反馈：“${feedback}”。` : '';
const multiHint = question.kind === '多选题' ? '；多选题判错可能是多选了某一项，也可能是漏选了某一项，请逐项重新核对，并选全所有正确项' : '';
const hint = `（注意：以下选择都已被判为错误：${triedText}。${feedbackHint}请重新审题，必须换一个没有试过的答案，不要重复这些选择${multiHint}。）`;
const hinted = { ...question, title: `${question.title}${hint}`.slice(0, 500) };
let letters = null;
try {
letters = validateAnswers([question], await askDeepSeek([hinted])).get(1);
if (letters && tried.some((entry) => sameLetters(letters, entry))) letters = null;
} catch (error) {
console.warn('视频弹题重答请求失败，改用排除法:', error);
}
if (!letters) {
// AI 仍给出旧答案时，再问一次，并明确要求“与之前所有尝试不同”
try {
const strictHint = `（这是一道${question.kind}。上一次提交的答案 ${triedText} 已被页面判错，必须给出与之前所有尝试都不同的答案${multiHint}。）`;
const strict = { ...question, title: `${question.title}${strictHint}`.slice(0, 500) };
const second = validateAnswers([question], await askDeepSeek([strict])).get(1);
if (second && !tried.some((entry) => sameLetters(second, entry))) {
console.log(`%cAI 重新判断后给出新答案：${second.join('')}`, 'color:#2196F3');
letters = second;
}
} catch (error) {
console.warn('视频弹题第二次重答请求失败，改用排除法:', error);
}
}
if (letters) return letters;
const fallback = fallbackLetters(question, state);
if (!fallback) throw new Error('所有选项都已尝试过，仍未答对，请手动完成');
return fallback;
}

function videoQuizOptionChecked(option) {
const el = option && option.element;
if (!el || !el.isConnected) return false;
const input = el.matches('input') ? el : el.querySelector('input');
if (input && input.checked) return true;
if (el.getAttribute('aria-checked') === 'true') return true;
return Boolean(el.querySelector('[aria-checked="true"], .checked, .selected, .is-checked, .checkbox-checked'));
}

async function clearVideoQuizSelections(question) {
let cleared = 0;
for (const option of question.options) {
if (!videoQuizOptionChecked(option)) continue;
const el = option.element;
try { el.scrollIntoView({ block: 'center' }); } catch (_) { /* 忽略 */ }
const targets = [];
const addTarget = (target) => {
if (target && !targets.includes(target)) targets.push(target);
};
addTarget(el);
const input = el.matches('input') ? el : el.querySelector('input');
addTarget(input);
const label = el.closest('label') || el.querySelector('label');
addTarget(label);
for (const child of el.querySelectorAll('i,em,span,b,div')) {
if (child.children.length) continue;
const className = String(child.className || '');
if (/check|select|active|box|on/i.test(className) || /^[A-H]$/.test(controlText(child))) addTarget(child);
}
for (const target of targets) {
fireClick(target);
await sleep(150);
if (!videoQuizOptionChecked(option)) {
cleared++;
break;
}
}
}
if (cleared) console.log(`%c多选题重答前已清空 ${cleared} 个已勾选选项`, 'color:#607D8B');
return cleared;
}

// 多段视频页面里，弹题属于哪一段：优先“和弹题同一文档、正在播放、尚未完成”的那一段
function videoForQuiz(question) {
const doc = question && question.doc ? question.doc : null;
const candidates = [];
const push = (video) => {
if (!video || !video.isConnected || candidates.includes(video)) return;
candidates.push(video);
};
if (typeof app._findAllVideos === 'function') {
try { app._findAllVideos(true).forEach(push); } catch (_) { /* 忽略 */ }
}
push(app._videoEl);
if (!candidates.length) {
try { push(app._getVideoEl()); } catch (_) { /* 忽略 */ }
}
const isDone = (video) => {
try { return typeof app._videoIsDone === 'function' ? app._videoIsDone(video) : false; } catch (_) { return false; }
};
const score = (video) => (doc && video.ownerDocument === doc ? 4 : 0) + (video.paused ? 0 : 2) + (isDone(video) ? 0 : 1);
return candidates.slice().sort((a, b) => score(b) - score(a))[0] || null;
}

// 弹题签名带上所属视频地址，保证同一道题出现在不同视频里时各自独立计次
function videoQuizScope(video) {
let src = '';
try { src = typeof app._videoSrcOf === 'function' ? app._videoSrcOf(video) : ''; } catch (_) { src = ''; }
return src ? src.replace(/[?#].*$/, '') : 'no-src';
}

async function handleVideoQuiz() {
if (stopped || videoQuizBusy || app._isChapterTest()) return;
if (videoQuizSuccessVisible()) {
app._videoQuizPending = true;
if (!clickVideoQuizContinue() && !findVideoQuizContinueButton() && Date.now() - videoQuizDiagAt > 10000) {
videoQuizDiagAt = Date.now();
const snippets = [];
for (const doc of videoQuizDocuments()) {
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('button,a,input[type="button"],[role="button"],div,span')); } catch (_) { continue; }
for (const el of nodes) {
const text = controlText(el);
if (!text || text.length > 30 || !/继续|下一题|查看解析/.test(text)) continue;
if (!visible(el)) continue;
snippets.push(`${el.tagName}.${String(el.className || '').slice(0, 30)}="${text}"`);
if (snippets.length >= 12) break;
}
if (snippets.length >= 12) break;
}
console.warn('%c已看到弹题通过提示，但没找到“继续学习”按钮。可见候选：', 'color:#FF9800', snippets);
}
return;
}
if (app._nextUnitPending) return;
if (Date.now() < videoQuizRetryAt) return;
let question = findVideoQuizCard();
const stored = activeVideoQuiz;
if (!question && stored && stored.card && stored.card.isConnected && visible(stored.card)) {
question = stored;
}
if (!question) {
const result = stored && stored.card && stored.card.isConnected && visible(stored.card) ? findVisibleVideoQuizResult() : null;
if (result && result.wrong) {
app._videoQuizPending = true;
if (!videoQuizStuckSince) videoQuizStuckSince = Date.now();
if (Date.now() - videoQuizStuckSince >= 8000) skipVideoQuizToNext('答错后 8 秒内仍无法重新选择');
} else {
activeVideoQuiz = null;
videoQuizStuckSince = 0;
app._videoQuizPending = false;
}
return;
}
activeVideoQuiz = question;
app._videoQuizPending = true;
videoQuizStuckSince = 0;
const video = videoForQuiz(question);
if (video) app._quizVideo = video;
const signatureTitle = question.title
.replace(/共\s*\d+\s*题[，,]\s*已答对\s*\d+\s*题/g, '')
.replace(/真遗憾[，,]?再?再接再厉[！!。]?/g, '')
.replace(/回答(?:错误|正确)[\s\S]*$/, '')
.replace(/正确答案\s*[：:][A-H\s、,，]*/g, '')
.trim();
const signature = `${videoQuizScope(video)}|${question.kind}:${signatureTitle}:${question.options.map((option) => option.letter).join('')}`;
const state = videoQuizState(signature);
state.signature = signature;
state.question = question;
if (attemptedVideoQuizzes.has(signature)) {
if (state.gaveUp && state.skipCount < 3) {
state.skipCount++;
skipVideoQuizToNext('已放弃重答');
}
return;
}
if (video && !video.paused) {
try { video.pause(); } catch (_) { /* 忽略 */ }
}
const text = clean(question.card.innerText);
const result = findVisibleVideoQuizResult();
const currentCorrect = correctCount(text);
const successByCounter = state.correctBefore >= 0 && currentCorrect > state.correctBefore;
const successByText = state.attempts > 0 && (isVideoQuizSuccess(text) || Boolean(result && result.success));
const successByDismiss = state.attempts > 0 && !isVideoQuizWrong(text) && !(result && result.wrong) &&
Boolean(findTextControl(question.card, CONTINUE_LABELS));
if (successByCounter || successByText || successByDismiss) {
attemptedVideoQuizzes.add(signature);
console.log('%c视频弹题回答正确', 'color:#4CAF50');
videoQuizBusy = true;
app._videoQuizActive = true;
let dismissed = false;
try {
dismissed = dismissVideoQuiz(question.card);
} finally {
videoQuizBusy = false;
app._videoQuizActive = false;
}
if (dismissed) {
activeVideoQuiz = null;
app._videoQuizPending = false;
videoQuizContinueAt = Date.now();
if (app._videoEndedDuringQuiz) scheduleVideoEndedNext(1500);
} else {
console.warn('%c视频弹题已答对，但暂时没找到“继续学习”按钮，2 秒后重试', 'color:#FF9800');
}
setTimeout(() => {
if (typeof app._resumeAfterVideoQuiz === 'function') app._resumeAfterVideoQuiz();
else if (typeof app._tryResumePlayback === 'function') app._tryResumePlayback('video-quiz-done');
}, 600);
return;
}
if (state.attempts >= videoQuizMaxAttempts(question)) {
state.gaveUp = true;
attemptedVideoQuizzes.add(signature);
console.error(`视频弹题已尝试 ${state.attempts} 次仍未通过`);
if (state.skipCount < 3) {
state.skipCount++;
skipVideoQuizToNext('多次作答仍未通过');
}
return;
}
if (state.attempts > 0 && !state.loggedUnknown && !isVideoQuizWrong(text) && !(result && result.wrong)) {
state.loggedUnknown = true;
console.log(`%c未识别的弹题反馈，仍会按“未通过”继续重答：${text.slice(-80)}`, 'color:#9E9E9E');
}
if (state.attempts > 0 && (isVideoQuizWrong(text) || Boolean(result && result.wrong))) {
console.warn('%c检测到上一次回答错误，准备重新作答', 'color:#FF9800');
}
const shownLetters = state.attempts > 0 ? shownCorrectLetters(text) : null;
videoQuizBusy = true;
app._videoQuizActive = true;
try {
if (state.attempts > 0) {
const retry = findRetryButton(question.card);
if (retry) {
console.log('%c点击弹题的“重新回答”按钮', 'color:#607D8B');
retry.click();
await sleep(600);
question = findVideoQuizCard() || question;
state.question = question;
activeVideoQuiz = question;
}
}
await clearVideoQuizSelections(question);
question = findVideoQuizCard() || question;
state.question = question;
activeVideoQuiz = question;
if (state.attempts === 0 && currentCorrect >= 0) state.correctBefore = currentCorrect;
const letters = await chooseVideoQuizLetters(question, state, shownLetters, text);
const targetLetters = new Set(letters);
const stale = question.options.filter((option) => !targetLetters.has(option.letter) && videoQuizOptionChecked(option));
if (state.attempts > 0 && stale.length) throw new Error(`多选题旧选项未能取消（${stale.map((option) => option.letter).join('、')}），暂不提交`);
console.log(`%c视频弹题第 ${state.attempts + 1} 次作答：${letters.join('')}`, 'color:#2196F3');
await selectAnswers([question], new Map([[1, letters]]));
const submit = findButtonIn(question.card, '提交');
if (!submit) throw new Error('视频弹题中未找到提交按钮');
submit.scrollIntoView({ block: 'center' });
submit.click();
state.attempts++;
state.tried.push(letters);
state.lastSubmittedAt = Date.now();
await confirmVideoQuizSubmit(question.card);
await sleep(800);
videoQuizRetryAt = Date.now() + 1200;
} catch (error) {
const failures = (videoQuizFailures.get(signature) || 0) + 1;
videoQuizFailures.set(signature, failures);
if (failures >= 3) {
state.gaveUp = true;
attemptedVideoQuizzes.add(signature);
console.error(`视频弹题自动作答失败（已尝试 ${failures} 次），准备点击“下一节”跳过:`, error);
if (state.skipCount < 3) {
state.skipCount++;
skipVideoQuizToNext('自动作答多次失败');
}
} else {
videoQuizRetryAt = Date.now() + 5000;
console.error(`视频弹题自动作答失败（第 ${failures} 次），5 秒后重试:`, error);
}
} finally {
videoQuizBusy = false;
app._videoQuizActive = false;
}
}

app._videoQuizVisibleNow = function () {
return Boolean(findVideoQuizCard()) || videoQuizSuccessVisible();
};

app.inspectVideoQuiz = function () {
const question = findVideoQuizCard();
if (question) {
return {
found: true,
type: question.kind,
question: question.title,
options: question.options.map((option) => `${option.letter}. ${option.text}`),
html: question.card.outerHTML.slice(0, 3000),
};
}
return {
found: false,
documents: videoQuizDocuments().map((doc) => ({
url: doc.location?.href || '',
submits: textSubmitCandidates(doc).length,
text: clean(doc.body?.innerText || '').slice(0, 500),
})),
};
};

videoQuizTimer = setInterval(() => {
if (stopped) return;
try {
confirmLeaveChapterDialog();
} catch (error) {
console.error('处理“任务点未完成”弹窗时出错:', error);
}
if (videoQuizBusy) return;
handleVideoQuiz().catch((error) => console.error('视频弹题检测失败:', error));
}, 2000);

}
function initializePlayer() {
const app = {
configs: {
autoplay: true,
retryInterval: 2000,
maxRetries: 10,
videoCheckInterval: 1000,
guardNoProgressMs: 7000,
guardResumeCooldownMs: 1500,
autoAdvanceNoVideo: false,
},
_videoEl: null,
_treeContainerEl: null,
_isPlaying: false,
_currentRetryCount: 0,
_noVideoRetryTimes: 0,
_videoQuizActive: false,
_videoQuizPending: false,
_videoEndedDuringQuiz: false,
_quizVideo: null,
_quizSkipAttempts: 0,
_checkInterval: null,
_eventVideoEl: null,
_boundVideoHandlers: null,
_nextUnitPending: false,
_destroyed: false,
_chapterAdvanceTimes: 0,
_cellData: {
cells: 0,
nCells: 0,
currentCellIndex: 0,
currentNCellIndex: 0,
currentVideoTitle: "",
},
get cellData() {
return this._cellData;
},
run() {
console.log("%c=== 学习通视频与章节测验助手 V800 启动（多视频版 2026-10-25）===", "color:#4CAF50;font-size:16px;font-weight:bold");
this._nextUnitPending = false;
this._chapterAdvanceTimes = 0;
this._getTreeContainer();
this._initCellData();
console.log(`当前学习步骤：${this._currentStepTitle() || '等待页面加载'}`);
this._videoEl = null;
this._getVideoEl();
this._clearCheckInterval();
this._bindStepNavigation();
this.play();
},
nextUnit() {
if (this._nextUnitPending) {
console.warn('%c已有小节切换正在进行，忽略重复请求', 'color:#FF9800');
return;
}
this._nextUnitPending = true;
this._clearCheckInterval();
console.log("%c=== 准备切换到下一小节 ===", "color:#2196F3;font-size:14px");
try {
const el = this._getTreeContainer();
const cells = el.children("ul").children("li");
const nCells = $(cells.get(this._cellData.currentCellIndex)).find('.posCatalog_select:not(.firstLayer)');
if (nCells.length > this._cellData.currentNCellIndex + 1) {
const nextNIndex = this._cellData.currentNCellIndex + 1;
console.log(`%c切换到同章节下一个视频: ${nextNIndex + 1}/${nCells.length}`, "color:#FF9800");
this.playCurrentIndex(nCells.get(nextNIndex));
} else {
const nextIndex = this._cellData.currentCellIndex + 1;
if (nextIndex >= cells.length) {
console.log("%c=====================================", "color:#4CAF50;font-size:16px");
console.log("%c==============本课程学习完成了==============", "color:#4CAF50;font-size:16px;font-weight:bold");
console.log("%c=====================================", "color:#4CAF50;font-size:16px");
return;
}
console.log(`%c切换到下一个章节: ${nextIndex + 1}/${cells.length}`, "color:#FF9800");
this._cellData.currentCellIndex = nextIndex;
this._cellData.currentNCellIndex = 0;
this.playCurrentIndex();
}
} catch (error) {
this._nextUnitPending = false;
console.error('切换下一小节失败:', error);
}
},
_clearCheckInterval() {
if (this._checkInterval) {
clearInterval(this._checkInterval);
this._checkInterval = null;
}
},
_startVideoMonitoring() {
this._clearCheckInterval();
this._guardLastTime = 0;
this._guardLastWallTs = 0;
this._guardLastResumeTs = 0;
this._checkInterval = setInterval(() => {
this._checkVideoStatus();
}, this.configs.videoCheckInterval);
},
_tryResumePlayback(reason) {
if (this._destroyed) return;
const now = Date.now();
if (now - this._guardLastResumeTs < this.configs.guardResumeCooldownMs) {
return;
}
this._guardLastResumeTs = now;
if (this._videoQuizActive || this._videoQuizPending) return;
if (typeof this._videoQuizVisibleNow === 'function' && this._videoQuizVisibleNow()) return;
const video = this._getVideoEl();
if (!video || !this._isPlaying) return;
if (typeof this._videoIsDone === 'function' && this._videoIsDone(video)) {
console.log('%c当前视频已经完成，不再重播，继续查找本页下一段视频', 'color:#4CAF50');
this._isPlaying = false;
this._clearCheckInterval();
if (typeof this._proceedAfterVideo === 'function') this._proceedAfterVideo('当前视频已完成', video);
else this.nextUnit();
return;
}
if (typeof this._videoEventHandle === 'function') this._videoEventHandle();
video.muted = true;
video.defaultMuted = true;
video.volume = 0;
console.log(`%c触发视频保活恢复(${reason})`, "color:#607D8B");
video.play().catch((e) => {
console.warn("直接恢复播放失败，尝试静音恢复:", e);
video.muted = true;
video.play().catch((err) => {
console.error("静音恢复播放失败:", err);
});
});
},
// 弹题答完后回到“弹题所属的那一段视频”，而不是回到本页第一段或已完成的视频
_resumeAfterVideoQuiz() {
const quizVideo = this._quizVideo;
this._quizVideo = null;
if (quizVideo && quizVideo.isConnected) {
if (typeof this._videoIsDone === 'function' && this._videoIsDone(quizVideo)) {
this._isPlaying = false;
this._clearCheckInterval();
if (typeof this._proceedAfterVideo === 'function') this._proceedAfterVideo('弹题结束，本段视频已完成', quizVideo);
else this.nextUnit();
return;
}
this._videoEl = quizVideo;
this._videoNextChecks = 0;
this._isPlaying = true;
if (typeof this._videoEventHandle === 'function') this._videoEventHandle();
}
this._tryResumePlayback('video-quiz-done');
},
_checkVideoStatus() {
if (this._destroyed) return;
if (this._videoQuizActive || this._videoQuizPending) return;
if (typeof this._videoQuizVisibleNow === 'function' && this._videoQuizVisibleNow()) return;
try {
const video = this._getVideoEl();
if (!video) return;
video.muted = true;
video.defaultMuted = true;
video.volume = 0;
if (video.paused && this._isPlaying) {
console.log("%c检测到视频暂停，尝试恢复播放...", "color:#FF5722");
this._tryResumePlayback("paused");
} else if (this._isPlaying && !video.ended) {
const now = Date.now();
const current = Number(video.currentTime || 0);
if (this._guardLastWallTs === 0) {
this._guardLastWallTs = now;
this._guardLastTime = current;
} else {
const stalled = Math.abs(current - this._guardLastTime) < 0.01;
const stalledMs = now - this._guardLastWallTs;
if (stalled && stalledMs >= this.configs.guardNoProgressMs) {
this._tryResumePlayback("no-progress");
this._guardLastWallTs = now;
this._guardLastTime = Number(video.currentTime || 0);
} else if (!stalled) {
this._guardLastWallTs = now;
this._guardLastTime = current;
}
}
}
if (video.ended && this._isPlaying) {
console.log("%c检测到视频结束，准备切换下一个...", "color:#9C27B0");
this._isPlaying = false;
this._nearEndSince = 0;
this._markVideoDone(video);
this._proceedAfterVideo('本段视频已结束', video);
} else if (this._isPlaying) {
const duration = Number(video.duration || 0);
const current = Number(video.currentTime || 0);
const nearEnd = Number.isFinite(duration) && duration > 0 && current > 0 && duration - current <= 1.5;
if (nearEnd) {
if (!this._nearEndSince) {
this._nearEndSince = Date.now();
console.log(`%c视频已停在结尾（${current.toFixed(1)}/${duration.toFixed(1)} 秒），等待结束事件...`, "color:#FF9800");
} else if (Date.now() - this._nearEndSince >= 6000) {
this._nearEndSince = 0;
console.log("%c长时间未收到视频结束事件，自动切换下一节或下一段视频", "color:#FF9800");
this._isPlaying = false;
this._clearCheckInterval();
this._markVideoDone(video);
this._proceedAfterVideo('本段视频已停在结尾', video);
}
} else {
this._nearEndSince = 0;
}
}
} catch (e) {
console.error("视频状态检查失败:", e);
}
},
_tryTimes: 0,
_stepAdvanceTimes: 0,
_stepSwitchAt: 0,
_stepSwitchPending: false,
_delayedNextUnitTimer: null,
_guardLastTime: 0,
_guardLastWallTs: 0,
_guardLastResumeTs: 0,
_nearEndSince: 0,
async play() {
try {
if (this._destroyed) return;
if (this._isChapterTest()) {
this._videoEl = null;
this._isPlaying = false;
this._clearCheckInterval();
this._advanceChapterTest();
return;
}
if (this._nextUnitPending) {
if (!this._pendingWaitLoggedAt || Date.now() - this._pendingWaitLoggedAt > 10000) {
this._pendingWaitLoggedAt = Date.now();
console.log('%c正在切换学习小节，暂缓播放', 'color:#607D8B');
}
setTimeout(() => this.play(), 1500);
return;
}
// 弹题还开着时不要先开始播，避免在弹题遮罩后面把视频播过去
if (this._videoQuizPending && typeof this._videoQuizVisibleNow === 'function' && this._videoQuizVisibleNow()) {
this._isPlaying = false;
this._clearCheckInterval();
if (!this._quizWaitLoggedAt || Date.now() - this._quizWaitLoggedAt > 10000) {
this._quizWaitLoggedAt = Date.now();
console.log('%c检测到视频弹题，暂缓播放，等待弹题处理完成', 'color:#FF9800');
}
setTimeout(() => this.play(), 2000);
return;
}
const el = this._getVideoEl();
if (el == null) {
// 阅读/图文任务点：先把内容区滚动到最底部，完成后再点“下一节”
if (typeof this._handleDocumentTask === 'function' && await this._handleDocumentTask()) return;
if (this._advanceLearningStep()) {
console.log("%c当前不在视频页，已尝试切到下一学习步骤，2秒后重试", "color:#607D8B");
setTimeout(() => {
this.play();
}, 2000);
return;
}
if (this._isChapterTest()) {
this._advanceChapterTest();
return;
}
const pageEmpty = typeof this._pageShowsNoContent === 'function' && this._pageShowsNoContent();
const noVideoRetries = this._noVideoRetryTimes || 0;
if (pageEmpty && noVideoRetries >= 10) {
this._isPlaying = false;
this._clearCheckInterval();
console.warn('%c当前小节显示“暂无内容”，0.8秒后自动切换到下一小节', 'color:#FF9800');
setTimeout(() => this.nextUnit(), 800);
return;
}
if (noVideoRetries < 20) {
this._noVideoRetryTimes = noVideoRetries + 1;
console.log(`%c暂未找到视频元素，1.5秒后重试 (${this._noVideoRetryTimes}/20)`, "color:#FF9800");
setTimeout(() => this.play(), 1500);
return;
}
this._isPlaying = false;
this._clearCheckInterval();
if (this.configs.autoAdvanceNoVideo || pageEmpty) {
console.warn(pageEmpty ? '%c当前小节显示“暂无内容”，自动切换到下一小节' : '%c当前小节未发现视频，按配置切换到下一小节', 'color:#FF9800');
this.nextUnit();
} else {
console.warn('%c当前小节未发现视频或可识别的学习步骤，已安全停止。确认无需完成课件后，可执行 app.nextUnit()。', 'color:#FF9800');
}
return;
}
this._noVideoRetryTimes = 0;
if (typeof this._videoIsDone === 'function' && this._videoIsDone(el)) {
// 第一次严格找可见视频，确认阶段允许播放暂时隐藏（还没渲染出来）的下一段
const nextVideo = this._nextPlayableVideo(el, (this._allDoneChecks || 0) >= 1);
if (nextVideo) {
this._allDoneChecks = 0;
console.log('%c当前视频已完成，先播放本页下一段视频', 'color:#4CAF50');
this._videoEl = nextVideo;
try {
nextVideo.muted = true;
nextVideo.defaultMuted = true;
nextVideo.volume = 0;
} catch (_) {}
this._isPlaying = false;
setTimeout(() => this.play(), 300);
return;
}
this._allDoneChecks = (this._allDoneChecks || 0) + 1;
this._isPlaying = false;
this._clearCheckInterval();
if (this._allDoneChecks <= 2) {
console.log(`%c本页视频均已完成，等待确认是否还有待加载的视频 (${this._allDoneChecks}/2)`, 'color:#FF9800');
setTimeout(() => this.play(), 2000);
return;
}
this._allDoneChecks = 0;
if (!this._canAdvanceAfterVideos()) return;
// 视频播完后本页可能还叠着图文（先视频后图文/穿插混排），先读完再切下一节
if (typeof this._handleDocumentTask === 'function' && await this._handleDocumentTask()) return;
// 图文处理的间隙可能又有新视频渲染出来，别被“已完成”的判断跳过
const lateVideo = this._nextPlayableVideo(el, true);
if (lateVideo) {
console.log('%c发现本页还有待播放的视频，先播放视频', 'color:#4CAF50');
this._videoEl = lateVideo;
this._allDoneChecks = 0;
this._isPlaying = false;
setTimeout(() => this.play(), 500);
return;
}
console.log('%c本页视频均已完成，自动切换下一节', 'color:#FF9800');
setTimeout(() => this.nextUnit(), 800);
return;
}
this._allDoneChecks = 0;
this._isPlaying = true;
this._videoEventHandle();
try {
el.muted = true;
el.defaultMuted = true;
el.volume = 0;
await el.play();
this._tryTimes = 0;
this._taskDialogResumes = 0;
console.log('%c视频开始播放，保持页面默认播放速度', 'color:#4CAF50');
this._startVideoMonitoring();
} catch (playError) {
console.error("视频播放失败:", playError);
this._handlePlayError(playError);
}
} catch (e) {
if (this._tryTimes >= this.configs.maxRetries) {
console.error("%c视频播放失败，已达到最大重试次数", "color:#F44336;font-weight:bold", e);
this._clearCheckInterval();
return;
}
this._tryTimes++;
console.log(`%c播放失败，${this.configs.retryInterval/1000}秒后重试 (${this._tryTimes}/${this.configs.maxRetries})`, "color:#FF9800");
setTimeout(() => {
this.play();
}, this.configs.retryInterval);
}
},
_advanceLearningStep() {
if (this._stepSwitchPending && Date.now() - this._stepSwitchAt < 4000) {
return true;
}
const currentStepTitle = this._currentStepTitle();

if (currentStepTitle === "章节测验" || currentStepTitle === "视频") {
return false;
}
const clickElement = (el, label) => {
if (!el) return false;
this._stepSwitchPending = true;
this._stepSwitchAt = Date.now();
console.log(`%c尝试点击${label}`, "color:#2196F3");
el.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, view: window }));
return true;
};
const videoTab = $(".prev_white:visible").filter((_, el) => {
const text = ($(el).text() || "").replace(/\s+/g, "");
return text === "2视频" || text === "视频";
}).get(0);
if (clickElement(videoTab, "“视频”页签")) {
return true;
}
return false;
},
_currentStepTitle() {
const cardsFrame = Array.from(document.querySelectorAll('iframe[src*="/knowledge/cards"]'))
.find((frame) => frame.getClientRects().length > 0);
if (cardsFrame) {
const num = new URL(cardsFrame.getAttribute('src'), location.href).searchParams.get('num');
if (num === '0') return '视频';
if (num === '1') return '章节测验';
}
const prevTitle = document.getElementsByClassName('prev_title')[0];
const text = prevTitle ? (prevTitle.title || prevTitle.textContent || '').trim() : '';
return text === '视频' || text === '章节测验' ? text : '';
},
_isChapterTest() {
return this._currentStepTitle() === '章节测验';
},
_advanceChapterTest() {
if (this._chapterAdvanceTimes >= 3) {
console.error('%c章节测验页面连续跳转失败，已停止以避免页面循环。请手动处理后执行 app.run()。', 'color:#F44336;font-weight:bold');
return;
}
const nextButton = $('#prevNextFocusNext:visible, #right1:visible, .nextChapter:visible').first().get(0);
if (!nextButton) {
console.warn('%c未找到章节测验的下一步按钮，已停止。', 'color:#FF9800');
return;
}
this._chapterAdvanceTimes++;
console.log('%c检测到章节测验，尝试进入下一学习步骤', 'color:#607D8B');
nextButton.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
setTimeout(() => this.play(), 2000);
},
_bindStepNavigation() {
if (this._stepNavigationBound) {
return;
}
this._stepNavigationBound = true;
const reenterVideoMode = () => {
this._videoEl = null;
this._quizVideo = null;
this._isPlaying = false;
this._stepSwitchPending = true;
this._stepSwitchAt = Date.now();
setTimeout(() => {
try {
this._initCellData();
} catch (e) {}
this.play();
}, 1800);
};
$(document).off('click.xuexitongPlayerV800', '.prev_white').on('click.xuexitongPlayerV800', '.prev_white', (e) => {
const text = ($(e.currentTarget).text() || "").replace(/\s+/g, "");
if (text.includes("视频") || text.includes("章节测验")) {
console.log(`%c检测到步骤切换点击：${text}，准备重新识别页面`, "color:#607D8B");
reenterVideoMode();
}
});
},
_handlePlayError(error) {
console.error("播放错误详情:", error);
const video = this._getVideoEl();
if (video) {
video.muted = true;
video.play().then(() => {
console.log("%c静音播放成功", "color:#4CAF50");
this._tryTimes = 0;
this._startVideoMonitoring();
if (this._delayedNextUnitTimer) {
clearTimeout(this._delayedNextUnitTimer);
this._delayedNextUnitTimer = null;
}
}).catch(e => {
console.error("静音播放也失败:", e);
if (this._delayedNextUnitTimer) {
clearTimeout(this._delayedNextUnitTimer);
}
this._isPlaying = false;
if (this._tryTimes >= this.configs.maxRetries) {
console.error('%c静音播放失败，已达到最大重试次数', 'color:#F44336;font-weight:bold', e);
return;
}
this._tryTimes++;
this._delayedNextUnitTimer = setTimeout(() => {
this._delayedNextUnitTimer = null;
this.play();
}, this.configs.retryInterval);
});
}
},
playCurrentIndex(nCell) {
this._nextUnitPending = false;
if (!nCell) {
const el = this._getTreeContainer();
const cells = el.children("ul").children("li");
const nCells = $(cells.get(this._cellData.currentCellIndex)).find('.posCatalog_select:not(.firstLayer)');
nCell = nCells.get(this._cellData.currentNCellIndex);
}
const $nCell = $(nCell);
const clickableSpan = $nCell.find(".posCatalog_name")[0];
if (!clickableSpan) {
console.error("%c===========找不到可点击的课程节点，播放下一个视频失败==============", "color:#F44336");
return;
}
console.log(`%c点击切换到: ${$(clickableSpan).attr('title') || '未知标题'}`, "color:#2196F3");
$(clickableSpan).click();
this._videoEl = null;
this._isPlaying = false;
console.log("%c等待视频加载...", "color:#FF9800");
setTimeout(() => {
this._initCellData();
if (this.configs.autoplay) {
this.play();
}
}, 3000);
},
_initCellData() {
this._noVideoRetryTimes = 0;
const el = this._getTreeContainer();
const cells = el.children("ul").children("li");
this._cellData.cells = cells.length;
let nCellCounts = 0;
let foundCurrent = false;
cells.each((i, v) => {
const nCells = $(v).find('.posCatalog_select:not(.firstLayer)');
nCellCounts += nCells.length;
nCells.each((j, e) => {
const _el = $(e);
if (_el.hasClass("posCatalog_active")) {
this._cellData.currentCellIndex = i;
this._cellData.currentNCellIndex = j;
foundCurrent = true;
const titleSpan = _el.find('.posCatalog_name')[0];
if (titleSpan) {
this._cellData.currentVideoTitle = $(titleSpan).attr('title');
}
}
});
});
this._cellData.nCells = nCellCounts;

if (!foundCurrent && nCellCounts > 0) {
console.warn("%c未找到当前激活的视频节点，可能需要手动选择", "color:#FF9800");
}
console.log(`%c课程信息: ${this._cellData.cells}章, ${this._cellData.nCells}节, 当前: 第${this._cellData.currentCellIndex + 1}章第${this._cellData.currentNCellIndex + 1}节`, "color:#607D8B");
},
_getTreeContainer() {
// 页面局部刷新可能替换课程目录节点，旧的 jQuery 引用失效时重新获取
const cached = this._treeContainerEl;
const cachedRoot = cached && cached[0];
if (!cached || cached.length <= 0 || !cachedRoot || !cachedRoot.isConnected) {
const el = $('#coursetree');
if (el.length <= 0) {
throw new Error("找不到视频列表");
}
this._treeContainerEl = el;
}
return this._treeContainerEl;
},
_findAllVideos(includeHidden = false) {
const preferred = [];
const fallback = [];
const seenDocs = new Set();
const seenVideos = new Set();
const addVideo = (video, inFrame) => {
if (!video || seenVideos.has(video)) return;
seenVideos.add(video);
let src = '';
try { src = video.currentSrc || video.getAttribute('src') || ''; } catch (_) {}
let hasSource = false;
try { hasSource = Boolean(video.querySelector('source')); } catch (_) {}
if (!src && !hasSource) return;
if (!includeHidden) {
let rects = null;
try { rects = video.getClientRects(); } catch (_) {}
if (!rects || !rects.length) return;
}
let isPlayer = false;
try {
isPlayer = /video_html5/i.test(video.id || '') || /video_html5/i.test(String(video.className || ''));
} catch (_) {}
if (inFrame || isPlayer) preferred.push(video);
else fallback.push(video);
};
const visit = (doc, depth, inFrame) => {
if (!doc || depth > 3 || seenDocs.has(doc)) return;
seenDocs.add(doc);
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('video')); } catch (_) { nodes = []; }
for (const video of nodes) addVideo(video, inFrame);
let frames = [];
try { frames = Array.from(doc.querySelectorAll('iframe')); } catch (_) { frames = []; }
for (const frame of frames) {
let childDoc = null;
try { childDoc = frame.contentDocument || (frame.contentWindow && frame.contentWindow.document); } catch (_) { continue; }
visit(childDoc, depth + 1, true);
}
};
visit(document, 0, false);
return preferred.length ? preferred.concat(fallback) : fallback;
},
_videoSrcOf(video) {
try { return video.currentSrc || video.getAttribute('src') || ''; } catch (_) { return ''; }
},
_videoIsDone(video) {
if (!video) return true;
try {
if (this._doneVideos && this._doneVideos.has(video)) {
const markedSrc = this._doneVideos.get(video);
const currentSrc = this._videoSrcOf(video);
if (!currentSrc || currentSrc === markedSrc) return true;
}
if (video.ended) return true;
const duration = Number(video.duration);
const current = Number(video.currentTime);
if (Number.isFinite(duration) && duration > 0 && current > 0 && duration - current <= 1.5) return true;
} catch (_) {}
return false;
},
_markVideoDone(video) {
if (!video) return;
if (!this._doneVideos) this._doneVideos = new Map();
try { this._doneVideos.set(video, this._videoSrcOf(video)); } catch (_) {}
},
_videoIsVisible(video) {
try { return Boolean(video && video.isConnected && video.getClientRects().length); } catch (_) { return false; }
},
_doneSrcSet() {
const srcs = new Set();
if (!this._doneVideos) return srcs;
try {
for (const src of this._doneVideos.values()) if (src) srcs.add(src);
} catch (_) {}
return srcs;
},
_nextPlayableVideo(exclude, allowHidden = false) {
let videos = [];
try { videos = this._findAllVideos(allowHidden); } catch (_) { return null; }
const doneSrcs = this._doneSrcSet();
const candidates = videos.filter((video) => {
if (exclude && video === exclude) return false;
if (this._videoIsDone(video)) return false;
const src = this._videoSrcOf(video);
if (src && doneSrcs.has(src)) return false;
return true;
});
if (!candidates.length) return null;
return candidates.find((video) => this._videoIsVisible(video)) || (allowHidden ? candidates[0] : null);
},
_switchToVideo(video, reason) {
if (!video) return false;
const current = this._videoEl;
if (current && current !== video) this._markVideoDone(current);
this._videoEl = video;
this._quizVideo = null;
this._videoNextChecks = 0;
this._isPlaying = false;
this._nearEndSince = 0;
this._guardLastTime = 0;
this._guardLastWallTs = 0;
this._guardLastResumeTs = 0;
this._detachVideoEvents();
try {
video.muted = true;
video.defaultMuted = true;
video.volume = 0;
} catch (_) {}
let total = 1;
try { total = this._findAllVideos(true).length || 1; } catch (_) {}
console.log(`%c${reason || '本段视频已结束'}，继续播放本页下一段视频（本页共 ${total} 段）`, 'color:#4CAF50');
setTimeout(() => this.play(), 800);
return true;
},
_continueWithNextVideo(reason, allowHidden = false) {
const next = this._nextPlayableVideo(this._videoEl, allowHidden);
if (!next) return false;
return this._switchToVideo(next, reason);
},
_proceedAfterVideo(reason, endedVideo) {
if (this._destroyed) return true;
if (this._nextUnitPending) return true;
if (endedVideo && this._videoEl && this._videoEl !== endedVideo) return true;
if (endedVideo && endedVideo.isConnected && this._doneVideos) {
const markedSrc = this._doneVideos.get(endedVideo);
const currentSrc = this._videoSrcOf(endedVideo);
if (markedSrc && currentSrc && currentSrc !== markedSrc && !endedVideo.ended) {
console.log('%c播放器已在同一个视频元素里换入下一段，继续播放', 'color:#4CAF50');
try { this._doneVideos.delete(endedVideo); } catch (_) {}
this._videoEl = endedVideo;
this._videoNextChecks = 0;
this._isPlaying = false;
setTimeout(() => this.play(), 500);
return true;
}
}
if (this._continueWithNextVideo(reason, (this._videoNextChecks || 0) >= 2)) {
this._videoNextChecks = 0;
return true;
}
this._videoNextChecks = (this._videoNextChecks || 0) + 1;
if (this._videoNextChecks <= 3) {
console.log(`%c本页暂未发现其他视频，${this._videoNextChecks}/3 次确认后进入下一节`, 'color:#FF9800');
setTimeout(() => this._proceedAfterVideo(reason, endedVideo), 1500);
return true;
}
this._videoNextChecks = 0;
if (!this._canAdvanceAfterVideos()) return true;
// 视频播完但本页还叠着图文：先回到统一流程读完再切下一节
if (typeof this._pageHasDocumentTasks === 'function' && this._pageHasDocumentTasks()) {
this._allDoneChecks = 2;
this._isPlaying = false;
this._clearCheckInterval();
console.log('%c本页视频已播完，检测到同页还有图文任务点，先完成图文', 'color:#4CAF50');
setTimeout(() => this.play(), 600);
return true;
}
console.log('%c本页视频已全部播放完成，进入下一节', 'color:#4CAF50');
this.nextUnit();
return true;
},
_canAdvanceAfterVideos() {
if ((this._taskDialogResumes || 0) >= 2) {
this._taskDialogResumes = 0;
console.warn('%c已两次返回本页仍未找到可播放的任务点，已停止自动推进，请手动检查剩余任务点。', 'color:#F44336;font-weight:bold');
return false;
}
return true;
},
_resumeAfterTaskDialog(label) {
if (this._isPlaying) return;
// 每次被弹窗退回都计数，只有真正恢复播放（或视频播完）时才清零，防止弹窗来回循环
this._taskDialogResumes = (this._taskDialogResumes || 0) + 1;
this._lastTaskResumeAt = Date.now();
this._nextUnitPending = false;
this._videoEl = null;
this._quizVideo = null;
this._videoNextChecks = 0;
this._allDoneChecks = 0;
this._isPlaying = false;
this._clearCheckInterval();
console.log(`%c已点击“${label}”，1.5 秒后继续完成本页剩余任务点`, 'color:#FF9800');
setTimeout(() => this.play(), 1500);
},
_getVideoEl() {
if (this._videoEl && this._videoEl.isConnected) {
// 平台把上一段播放器隐藏、又渲染出新的可见视频时，跟随新的那一段
let cachedVisible = true;
try { cachedVisible = this._videoIsVisible(this._videoEl); } catch (_) {}
if (!cachedVisible) {
let stillPlaying = false;
try { stillPlaying = !this._videoEl.paused && !this._videoEl.ended; } catch (_) {}
if (!stillPlaying) {
const alt = this._nextPlayableVideo(this._videoEl);
if (alt) {
console.log('%c上一段播放器已隐藏，切换到本页新出现的视频', 'color:#4CAF50');
this._videoEl = alt;
try {
alt.muted = true;
alt.defaultMuted = true;
alt.volume = 0;
} catch (_) {}
return alt;
}
}
}
return this._videoEl;
}
try {
const allowHidden = (this._noVideoRetryTimes || 0) >= 6;
const videos = this._findAllVideos(allowHidden);
const doneSrcs = this._doneSrcSet();
const fresh = videos.filter((video) => {
if (this._videoIsDone(video)) return false;
const src = this._videoSrcOf(video);
if (src && doneSrcs.has(src)) return false;
return true;
});
const active = fresh.find((video) => this._videoIsVisible(video)) || fresh[0] || videos[0] || null;
if (active) {
this._videoEl = active;
active.muted = true;
active.defaultMuted = true;
active.volume = 0;
}
} catch (e) {
console.error("获取视频元素失败:", e);
return null;
}
return this._videoEl || null;
},
_videoEventHandle() {
const el = this._videoEl;
if (!el) {
console.log("videoEl未加载");
return;
}
if (this._eventVideoEl === el) return;
this._detachVideoEvents();
this._eventVideoEl = el;
this._boundVideoHandlers = {
ended: this._handleVideoEnded.bind(this),
loadedmetadata: this._handleVideoLoaded.bind(this),
play: this._handleVideoPlay.bind(this),
pause: this._handleVideoPause.bind(this),
};
el.addEventListener('ended', this._boundVideoHandlers.ended);
el.addEventListener('loadedmetadata', this._boundVideoHandlers.loadedmetadata);
el.addEventListener('play', this._boundVideoHandlers.play);
el.addEventListener('pause', this._boundVideoHandlers.pause);
},
_detachVideoEvents() {
if (!this._eventVideoEl || !this._boundVideoHandlers) return;
this._eventVideoEl.removeEventListener('ended', this._boundVideoHandlers.ended);
this._eventVideoEl.removeEventListener('loadedmetadata', this._boundVideoHandlers.loadedmetadata);
this._eventVideoEl.removeEventListener('play', this._boundVideoHandlers.play);
this._eventVideoEl.removeEventListener('pause', this._boundVideoHandlers.pause);
this._eventVideoEl = null;
this._boundVideoHandlers = null;
},
_handleVideoEnded(e) {
if (this._destroyed) return;
const target = e && e.target && e.target.tagName === 'VIDEO' ? e.target : null;
// 迟到的旧视频结束事件、或正在切换小节的过渡期，都不参与推进
if (target && this._videoEl && target !== this._videoEl) return;
if (this._nextUnitPending) return;
const title = this._cellData.currentVideoTitle;
console.warn(`%c============'${title}' 播放完成=============`, "color:#4CAF50;font-weight:bold");
this._isPlaying = false;
this._clearCheckInterval();
const endedVideo = target || this._videoEl;
this._markVideoDone(endedVideo);
setTimeout(() => {
const quizVisible = typeof this._videoQuizVisibleNow === 'function' && this._videoQuizVisibleNow();
if (this._videoQuizActive || this._videoQuizPending || quizVisible) {
this._videoEndedDuringQuiz = true;
this._endedVideoDuringQuiz = endedVideo;
console.log('%c视频已结束，但弹题还没处理完，等弹题结束后再切换下一节', 'color:#FF9800');
if (typeof this._scheduleVideoEndedNext === 'function') this._scheduleVideoEndedNext(2000);
return;
}
if (typeof this._proceedAfterVideo === 'function') this._proceedAfterVideo('本段视频已结束', endedVideo);
else this.nextUnit();
}, 1500);
},
_handleVideoLoaded(e) {
console.log(`%c============视频加载完成=============`, "color:#2196F3");
if (this.configs.autoplay && !this._isPlaying) {
this.play();
}
},
_handleVideoPlay(e) {
if (e && e.target && e.target.tagName === 'VIDEO' && this._videoEl && e.target !== this._videoEl) return;
const title = this._cellData.currentVideoTitle;
console.info(`%c============'${title}' 开始播放=============`, "color:#4CAF50");
this._isPlaying = true;
this._stepSwitchPending = false;
const video = this._getVideoEl();
this._guardLastTime = Number(video?.currentTime || 0);
this._guardLastWallTs = Date.now();
if (this._delayedNextUnitTimer) {
clearTimeout(this._delayedNextUnitTimer);
this._delayedNextUnitTimer = null;
}
},
_handleVideoPause(e) {
console.log(`%c============视频暂停=============`, "color:#FF9800");
},
_bindPageGuards() {
const preventPause = (e) => {
e.stopPropagation();
e.preventDefault();
};
const resumePlaybackNow = () => this._tryResumePlayback('page-event');
this._pageGuards = { preventPause, resumePlaybackNow };
document.addEventListener('mouseleave', preventPause);
window.addEventListener('mouseleave', preventPause);
document.addEventListener('mouseout', preventPause);
window.addEventListener('mouseout', preventPause);
window.addEventListener('blur', resumePlaybackNow);
document.addEventListener('visibilitychange', resumePlaybackNow);
},
destroy() {
this._isPlaying = false;
this._clearCheckInterval();
this._detachVideoEvents();
if (this._delayedNextUnitTimer) clearTimeout(this._delayedNextUnitTimer);
$(document).off('.xuexitongPlayerV800');
if (this._pageGuards) {
const { preventPause, resumePlaybackNow } = this._pageGuards;
document.removeEventListener('mouseleave', preventPause);
window.removeEventListener('mouseleave', preventPause);
document.removeEventListener('mouseout', preventPause);
window.removeEventListener('mouseout', preventPause);
window.removeEventListener('blur', resumePlaybackNow);
document.removeEventListener('visibilitychange', resumePlaybackNow);
this._pageGuards = null;
}
},
};
attachQuizAutomation(app);
PAGE.app = app;
PAGE[APP_KEY] = app;

try {
app.run();
app._bindPageGuards();
} catch (error) {
console.error("%c脚本运行失败: ", "color:#F44336;font-weight:bold", error.message);
console.log("请检查是否在正确的课程播放页面，或者页面结构是否再次发生改变。");
}
}
})();
:__XXT_BROWSER_END__
