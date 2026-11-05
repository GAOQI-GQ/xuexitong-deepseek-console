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
                { role: 'system', content: '按题意回答全部题目。注意：题干或选项可能经过网页防复制处理，出现个别汉字被替换、插入无关字，或词语看起来不通顺。先结合上下文和选项在内部还原最可能的原句，再按还原后的题意作答；不要把明显异常的替换字当作专业术语，也不要因无法逐字还原而放弃。每题都必须作答：带 options 的选择题只用该题提供的选项字母且不可重复，单选和判断选一个，多选列出所有正确项，放在 letters 里；带 blanks 的填空题/简答题不用字母，按空的数量依次给出文字答案，放在 texts 里，texts 的数量必须等于 blanks，简答/论述/名词解释题给一段完整、简洁的作答。不确定时选最可能的答案。id须对应题号。只输出JSON：{"answers":[{"id":1,"letters":["A"]},{"id":2,"texts":["答案一","答案二"]}]}。' },
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

// 页面长时间没有进展时，把页面文字和可点元素发给模型，让它选一个能继续学习的动作。
// 注意：DeepSeek 的对话接口只收文字，不收截图，所以这里传的是“页面内容识别结果”，不是图片像素。
const ACTION_SYSTEM_PROMPT = '你是“学习通”网课自动学习脚本的页面恢复助手。脚本在一张页面上长时间没有任何进展，需要你根据页面文字和可点元素，选出一个最可能让学习继续下去的操作。只能从以下动作里选一个：{"action":"click","id":编号,"reason":"简短理由"} 点击编号对应的元素；{"action":"scroll","reason":"简短理由"} 页面下方可能还有没加载出来的内容；{"action":"next","reason":"简短理由"} 当前小节确实无法继续，跳到下一节；{"action":"wait","reason":"简短理由"} 还需要等页面加载；{"action":"skip","reason":"简短理由"} 当前小节无法自动完成，跳过。优先选“重做、重新作答、继续学习、开始答题、下一题、确定、关闭、去学习”这类能让流程继续的元素；页面内容明显没显示完时选 scroll；确实无法继续才选 next 或 skip。禁止选择“交卷、提交、删除、清空、退出”类元素。页面上的“未达到及格线，请重做”只是成绩状态文字，不是按钮，不要选它。如果页面显示的是测验成绩未达标/请重做，绝对不要点“视频、播放、音频、观看、目录、章节名”这类会离开成绩页的入口，也不要选 next/skip，只在“重做、开始答题、继续、确定、关闭、查看详情”这类测验相关元素里选；找不到就选 scroll 或 wait。id 必须是 controls 里存在的编号。不确定时选 wait。只输出 JSON，不要输出其它文字。';

function validAction(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
    if (!['click', 'scroll', 'next', 'wait', 'skip'].includes(value.action)) return false;
    if (value.action === 'click' && !Number.isInteger(value.id)) return false;
    return true;
}

async function requestAction(snapshot, apiKey, fetchImpl = fetch) {
    let lastProblem = '';
    for (const [index, settings] of ATTEMPTS.entries()) {
        const body = {
            model: 'deepseek-flash',
            stream: false,
            response_format: { type: 'json_object' },
            ...settings,
            messages: [
                { role: 'system', content: ACTION_SYSTEM_PROMPT },
                { role: 'user', content: JSON.stringify(snapshot) },
            ],
        };
        let response;
        try {
            response = await fetchImpl(API_URL, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
                body: JSON.stringify(body),
                signal: AbortSignal.timeout(180000),
            });
        } catch (error) {
            if (index + 1 < ATTEMPTS.length && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
                lastProblem = 'DeepSeek 请求超时（180 秒）';
                console.warn(`${lastProblem}，改用降级配置重试`);
                continue;
            }
            throw error;
        }
        const data = await response.json().catch(() => null);
        if (!response.ok) {
            const detail = data?.error?.message || data?.error || data?.message || '';
            throw new Error(`DeepSeek API 返回 HTTP ${response.status}${detail ? `：${detail}` : ''}`);
        }
        const choice = data?.choices?.[0];
        const reason = choice?.finish_reason;
        if (reason === 'length') {
            lastProblem = 'DeepSeek 输出达到长度上限';
        } else if (reason !== 'stop') {
            throw new Error(`DeepSeek 未正常结束（finish_reason=${reason ?? '缺失'}）`);
        } else {
            try {
                const parsed = JSON.parse(choice.message?.content || '');
                const action = parsed?.action && typeof parsed.action === 'object' ? parsed.action : parsed;
                if (validAction(action)) return action;
                lastProblem = 'DeepSeek 返回的操作格式不正确';
            } catch {
                lastProblem = 'DeepSeek 返回空内容或无法解析 JSON';
            }
        }
        if (index + 1 < ATTEMPTS.length) console.warn(`${lastProblem}，正在重试`);
    }
    throw new Error(`${lastProblem}；没有获得可执行的页面恢复动作`);
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

function runPowerShell(script, extraEnv) {
    return execFileSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script], {
        env: { ...process.env, ...extraEnv },
        encoding: 'utf8',
        windowsHide: true,
    }).trim();
}

function dpapiEncrypt(value) {
    const script = 'Add-Type -AssemblyName System.Security; $b=[Text.Encoding]::UTF8.GetBytes($env:XXT_KEY); [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))';
    return runPowerShell(script, { XXT_KEY: value });
}

function dpapiDecrypt(value) {
    const script = 'Add-Type -AssemblyName System.Security; $b=[Convert]::FromBase64String($env:XXT_ENC); [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b,$null,[Security.Cryptography.DataProtectionScope]::CurrentUser))';
    return runPowerShell(script, { XXT_ENC: value });
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

function validSnapshot(snapshot) {
    if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot)) return false;
    if (typeof snapshot.reason !== 'string' || snapshot.reason.length > 300) return false;
    if (snapshot.url !== undefined && (typeof snapshot.url !== 'string' || snapshot.url.length > 2000)) return false;
    if (snapshot.title !== undefined && (typeof snapshot.title !== 'string' || snapshot.title.length > 200)) return false;
    if (snapshot.chapter !== undefined && (typeof snapshot.chapter !== 'string' || snapshot.chapter.length > 200)) return false;
    if (typeof snapshot.text !== 'string' || snapshot.text.length > 6000) return false;
    if (!Array.isArray(snapshot.controls) || snapshot.controls.length > 60) return false;
    return snapshot.controls.every((c, i) => c && typeof c === 'object' &&
        Number.isInteger(c.id) && c.id === i + 1 &&
        typeof c.tag === 'string' && c.tag.length > 0 && c.tag.length <= 24 &&
        typeof c.text === 'string' && c.text.length > 0 && c.text.length <= 160 &&
        (c.cls === undefined || (typeof c.cls === 'string' && c.cls.length <= 160)));
}

// 弹题和章节测验可能同时向本地服务要答案。以前只允许一个请求在跑，后到的
// 直接回 429“上一批题目仍在处理”，脚本收到就放弃作答，测验页停在原地不动。
// 现在改成排队：先到先做，后面的按顺序等，最多排 8 个。
const MAX_QUEUED = 8;
let queueTail = Promise.resolve();
let queued = 0;

function enqueueAnswer(task) {
    queued += 1;
    const result = queueTail.then(task);
    queueTail = result.then(() => {}, () => {});
    return result.finally(() => { queued -= 1; });
}

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
    if (req.method !== 'POST' || (req.url !== '/answer' && req.url !== '/act')) {
        send(res, 404, { error: '未找到接口' }, origin);
        return;
    }
    if (!apiKey) {
        send(res, 409, { error: '尚未设置 DeepSeek API Key，请打开 http://127.0.0.1:37841/setup 设置' }, origin);
        return;
    }
    if (!String(req.headers['content-type'] || '').startsWith('application/json')) {
        send(res, 415, { error: '仅接受 JSON' }, origin);
        return;
    }
    let payload;
    try {
        let raw = '';
        for await (const chunk of req) {
            raw += chunk.toString('utf8');
            if (raw.length > 100000) throw new Error('请求内容过大');
        }
        payload = JSON.parse(raw);
        if (req.url === '/answer') {
            if (!validQuestions(payload.questions)) throw new Error('题目格式不正确');
        } else if (!validSnapshot(payload.snapshot)) {
            throw new Error('页面内容格式不正确');
        }
    } catch (error) {
        send(res, 502, { error: error.message }, origin);
        return;
    }
    if (queued >= MAX_QUEUED) {
        send(res, 503, { error: '排队的题目太多，请稍后再试' }, origin);
        return;
    }
    if (queued > 0) console.log(`前面还有 ${queued} 批题目在排队，本次等它们做完再调用 DeepSeek`);
    try {
        if (req.url === '/act') {
            const action = await enqueueAnswer(() => requestAction(payload.snapshot, apiKey));
            console.log(`页面恢复建议：${action.action}${action.id ? ` #${action.id}` : ''}（${action.reason || '无理由'}）`);
            send(res, 200, { action }, origin);
            return;
        }
        const answers = await enqueueAnswer(() => requestAnswers(payload.questions, apiKey));
        send(res, 200, { answers }, origin);
    } catch (error) {
        send(res, 502, { error: error.message }, origin);
    }
});

function findEdge() {
    const candidates = [
        process.env['ProgramFiles(x86)'] && join(process.env['ProgramFiles(x86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
        process.env.ProgramFiles && join(process.env.ProgramFiles, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
    ].filter(Boolean);
    return candidates.find((candidate) => existsSync(candidate));
}

// 优先用 Edge 打开（--app 是独立小窗口）；没有 Edge 时退回系统默认浏览器
function launchBrowser(url, appWindow) {
    const edge = findEdge();
    if (edge) {
        spawn(edge, appWindow ? [`--app=${url}`, '--window-size=480,720'] : ['--new-window', url], { detached: true, stdio: 'ignore' }).unref();
        return 'edge';
    }
    if (process.platform === 'win32') {
        spawn('cmd', ['/c', 'start', '', url], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
        return 'default';
    }
    spawn('xdg-open', [url], { detached: true, stdio: 'ignore' }).unref();
    return 'default';
}

function openSetupPage() {
    if (process.env.XXT_NO_BROWSER === '1') return;
    const url = `http://127.0.0.1:${PORT}/setup`;
    try {
        launchBrowser(url, true);
    } catch (error) {
        console.warn('无法自动打开设置页，请手动访问：' + url);
    }
}

const CHAOXING_URL = 'https://i.chaoxing.com/';
let chaoxingOpened = false;

function openChaoxingPage() {
    if (process.env.XXT_NO_BROWSER === '1' || chaoxingOpened) return;
    chaoxingOpened = true;
    try {
        if (launchBrowser(CHAOXING_URL, false) === 'edge') console.log('已在 Edge 打开学习通：' + CHAOXING_URL);
        else console.log('已用默认浏览器打开学习通：' + CHAOXING_URL);
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

// —— 模块级共享工具 / 状态 ——
// attachQuizAutomation(app) 和 app 自己的方法是同一份脚本里的两套作用域：
// 写在 attachQuizAutomation 里的 const/let，app 的方法根本看不到（调用时直接 ReferenceError）。
// 所以两边都要用的东西统一放这一层。
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// 图文占用标记：attachQuizAutomation 里写入/解除，app 的停滞自检负责超时复位并读取状态
let docTaskBusy = false;
let docTaskBusySince = 0;
let docTaskWakeAt = 0;

// —— 渲染进程内存保护 ——
// 课程页往往一开就是几十个小时：平台每次交卷/换框架都重建一大块 DOM，DevTools 控制台也一直累积，
// 渲染进程迟早撑到 “Out of Memory”，整个标签页直接崩掉，脚本再聪明也救不回来。
// 辅助窗口能在整页刷新后自动重新注入脚本，所以这里在内存偏高或连续运行太久时主动刷新一次，
// 把渲染进程的内存清零后接着学。判据写成纯函数（不碰 DOM），方便测试覆盖忙时推迟/冷却/阈值。
const MEMORY_RELOAD_COOLDOWN = 5 * 60 * 1000;
const MEMORY_RELOAD_HEAP = 1200 * 1024 * 1024;
const MEMORY_RELOAD_URGENT_HEAP = 1600 * 1024 * 1024;
const MEMORY_RELOAD_UPTIME = 3 * 60 * 60 * 1000;
const MEMORY_RELOAD_BUSY_WAIT = 3 * 60 * 1000;
// 页面连续多久没有任何进展才让 AI 识别页面（停滞自检的 75 秒重启之后再等一会儿）
const AI_RESCUE_IDLE = 90000;
// 达到条件返回 true。busy=true（答题/等 AI/图文滚动）时先等空闲；
// 但内存已经很危险或已经等满 3 分钟，就算忙也要刷——宁可重做一轮，也不能让标签页崩。
function memoryRefreshDecision(input) {
const { now = 0, heap = 0, limit = 0, busy = false, busySince = 0, uptime = 0, lastReloadAt = 0 } = input || {};
if (lastReloadAt && now - lastReloadAt < MEMORY_RELOAD_COOLDOWN) return false;
const hot = heap > MEMORY_RELOAD_HEAP || (limit > 0 && heap > limit * 0.6);
const stale = uptime > MEMORY_RELOAD_UPTIME;
if (!hot && !stale) return false;
if (busy) {
const waited = busySince ? now - busySince : 0;
const urgent = heap > MEMORY_RELOAD_URGENT_HEAP || uptime > MEMORY_RELOAD_UPTIME * 1.5;
if (!urgent && waited < MEMORY_RELOAD_BUSY_WAIT) return false;
}
return true;
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
// 整页刷新会自动丢掉脚本，只有辅助窗口确实在（本次由它注入，或刚刚成功打开），才允许脚本自己刷新页面
PAGE.__xuexitongKeeperReady = startedByKeeper || PAGE.__xuexitongKeeperReady === true;
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
try {
keeper.document.title = '学习通自动任务辅助窗口';
} catch (error) {
// 同名的窗口如果是别的页面留下的（跨域，读不到它的内容），先关掉再开一个干净的。
// 以前这里直接放弃，残留的旧窗口会一直显示“自动恢复遇到错误”。
try { keeper.close(); } catch (_) { /* 忽略 */ }
keeper = PAGE.open('', 'xuexitongConsoleKeeper', 'width=360,height=150');
if (!keeper) throw new Error('浏览器阻止了辅助窗口');
keeper.document.title = '学习通自动任务辅助窗口';
}
keeper.document.body.innerHTML = '<p style="font:16px sans-serif;padding:12px">GQ提醒您：学习通自动任务正在运行。请保持此窗口打开；课程页整页跳转后，它会重新启动脚本。</p>';
keeper.__xuexitongSource = `(${xuexitongMain.toString()})();`;
keeper.__xuexitongLastUrl = location.href;
keeper.__xuexitongLastInjectionAt = Date.now();
if (!keeper.__xuexitongKeeperTimer) {
keeper.eval(`window.__xuexitongKeeperTimer = setInterval(function () {
                    function note(text) {
                        var status = window.document.getElementById('xxtKeeperStatus');
                        if (!status) {
                            status = window.document.createElement('p');
                            status.id = 'xxtKeeperStatus';
                            status.style.cssText = 'font:13px sans-serif;padding:0 12px 10px;color:#c62828';
                            window.document.body.appendChild(status);
                        }
                        status.textContent = text;
                    }
                    try {
                        var page = window.opener;
                        if (!page) return;
                        var closed = true;
                        try { closed = page.closed; } catch (e) { closed = true; }
                        if (closed) { clearInterval(window.__xuexitongKeeperTimer); window.close(); return; }
                        var href = '';
                        try {
                            href = page.location.href;
                        } catch (e) {
                            // 打开者已经不在学习通（旧页面关掉了，或者这个窗口是上一轮残留的）：
                            // 这里什么也做不了。不要每秒报错，等用户在课程页重新点书签时，
                            // 页面会把这个窗口关掉重新打开。
                            note('GQ提醒您：这个辅助窗口对应的课程页已经关闭或跳到了别的站点，请在课程页重新点一次书签。');
                            return;
                        }
                        var status = window.document.getElementById('xxtKeeperStatus');
                        if (status) status.textContent = '';
                        if (!/^https:\\/\\/([a-z0-9-]+\\.)*chaoxing\\.com\\/mycourse\\/studentstudy/i.test(href)) return;
                        if (href !== window.__xuexitongLastUrl) {
                            window.__xuexitongLastUrl = href;
                            window.__xuexitongLastInjectionAt = Date.now() - 30000;
                        }
                        if (page.document.readyState !== 'complete' || !page.document.querySelector('#coursetree')) return;
                        var beat = page.__xuexitongLastBeat || 0;
                        if (page.__xuexitongConsoleDeepSeek || page.__xuexitongConsoleDeepSeekBootTimer) {
                            // 脚本还在，但页面可见却 90 秒没有心跳：脚本已经卡死，重新注入把它重启
                            if (page.document.visibilityState !== 'visible') return;
                            if (!beat || Date.now() - beat < 90000) return;
                            if (Date.now() - (window.__xuexitongDeadHandledAt || 0) < 60000) return;
                            window.__xuexitongDeadHandledAt = Date.now();
                            window.__xuexitongLastInjectionAt = 0;
                            try { page.console.warn('GQ提醒您：检测到脚本心跳停止 90 秒，正在自动重启脚本'); } catch (e) {}
                        }
                        if (Date.now() - window.__xuexitongLastInjectionAt < 30000) return;
                        window.__xuexitongLastInjectionAt = Date.now();
                        page.__xuexitongAutoInjected = true;
                        page.eval(window.__xuexitongSource);
                    } catch (error) {
                        if (Date.now() - (window.__xuexitongLastErrorAt || 0) > 30000) {
                            window.__xuexitongLastErrorAt = Date.now();
                            note('GQ提醒您：整页跳转后的自动恢复暂时出错：' + error.message);
                            console.warn('学习通整页跳转后的自动恢复暂不可用:', error);
                        }
                    }
                }, 1000);`);
}
keeper.blur();
PAGE.focus();
PAGE.__xuexitongKeeperReady = true;
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
// 页面里常常同时留着好几个任务点框架（视频 num=0、测验 num=1 都在 DOM 里），
// 只按“第一个有尺寸的框架”判断会把当前步骤认错：明明屏幕上是已完成的视频，
// 却被当成章节测验去等永远不会出现的题目。这里按“内容区真正显示的是哪个框架”来选：
// 先用内容区中心点最上层命中谁（浏览器真实布局），读不到坐标（例如测试环境）再退回面积最大的那个。
function displayedCardsFrame() {
const isCards = (frame) => {
try { return Boolean(frame) && frame.tagName === 'IFRAME' && /\/knowledge\/cards/.test(frame.getAttribute('src') || ''); } catch (_) { return false; }
};
try {
const cx = Math.floor((window.innerWidth || 1280) * 0.35);
const cy = Math.floor((window.innerHeight || 800) * 0.45);
let el = document.elementFromPoint(cx, cy);
while (el && el !== document.body) {
if (isCards(el)) return el;
el = el.parentElement;
}
} catch (_) { /* jsdom 或页面重建时读不到坐标 */ }
let best = null;
let bestArea = 0;
try {
for (const frame of document.querySelectorAll('iframe[src*="/knowledge/cards"]')) {
let rect = null;
try { rect = frame.getClientRects()[0]; } catch (_) { rect = null; }
if (!rect) continue;
const area = (rect.width || 0) * (rect.height || 0);
if (!best || area > bestArea) {
best = frame;
bestArea = area;
}
}
} catch (_) { /* 忽略 */ }
if (best) return best;
try {
return Array.from(document.querySelectorAll('iframe[src*="/knowledge/cards"]'))
.find((frame) => frame.getClientRects().length > 0) || null;
} catch (_) { return null; }
}

// 测验、弹题、图文、小节切换都在这里，负责给 app 补上对应能力。
// 其中 _currentStepTitle 是“包住”app 原实现、destroy 包在原 destroy 外面、_advanceChapterTest 直接替换，
// 以后改这几处逻辑请改这里，不要去 app 对象里再写一份同名实现（否则就是两套逻辑并行）。
function attachQuizAutomation(app) {
const attemptedQuizzes = new Set();
const attemptedVideoQuizzes = new Set();
const videoQuizFailures = new Map();
const videoQuizStates = new Map();
let quizBusy = false;
let quizLoadRetries = 0;
let quizAnswerRetries = 0;
// 连续跳过多少个“目录里是测验、内容区却是空的”小节（真答上一份测验就清零）
let emptyQuizSkips = 0;
// 上一次跳过的是哪一节、什么时候跳的：同一节刚跳过又被平台拉回来，说明这里确实有未完成任务点
let lastSkippedQuiz = { label: '', at: 0 };
// 同一节反复被“还有任务点未完成”弹回来：平台不给重做入口时脚本怎么做都过不去，
// 记下次数并在第 3 次停下，免得“跳节→被带回→再跳节”无限刷屏
const quizBounceCounts = new Map();
let quizStuckLabel = '';
// initializePlayer 里的停滞自检/AI 恢复要能问一句“这一节是不是已经停手了”
app._quizStuckHere = function () {
return Boolean(quizStuckLabel) && quizStuckLabel === (activeCatalogLabel() || '');
};
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
// 测验/弹题正在处理时本来就慢（等题目、等 DeepSeek），停滞自检要跳过这些阶段
app._quizAutomationBusy = function () {
return Boolean(quizBusy || videoQuizBusy);
};

const clean = (value) => String(value || '').replace(/\s+/g, ' ').trim();
const visible = (el) => Boolean(el && el.isConnected && el.getClientRects().length &&
el.ownerDocument.defaultView.getComputedStyle(el).visibility !== 'hidden');
const kindPattern = /[\[【](单选题|多选题|判断题)[\]】]/;
// 新版卷面会把同一个题型标签重复渲染（标题里出现两个【单选题】）。重复的同名标签
// 只算一种题型，不能像两种题型那样把外层容器排除掉，否则整道题都会被跳过
function distinctKindTags(text, pattern) {
const tags = String(text || '').match(new RegExp(pattern.source, 'g')) || [];
return new Set(tags.map((tag) => clean(tag).replace(/[\[\]【】]/g, '')));
}
// 目录/搜索框长得很像填空输入框：有搜索字样时一律不当成填空，避免凭空多出一道填空题
function searchLikeInput(el) {
if (!el || el.tagName !== 'INPUT') return false;
const type = String(el.type || '').toLowerCase();
const hint = `${el.placeholder || ''} ${el.getAttribute('aria-label') || ''} ${el.id || ''} ${el.className || ''} ${el.name || ''}`;
if (type === 'search' && !/第\s*[0-9一二三四五六七八九十]+\s*空/.test(hint)) return true;
return /搜索|查找|search|keyword/i.test(hint);
}
// 成绩状态文字（“未达到及格线，请重做”）：它不是按钮，既不能点，也不能让 AI 当成入口
const quizStatusText = /未达到|未达标|不及格|未通过|已提交|已完成/;

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

// 目录里标着测验、内容区却什么都没有：测验已经做过，或者这一节压根没放题目。
// 这种小节永远不会再出现“提交”按钮，以前会干等 120 秒、重试 3 次，最后停下来等人手动处理。
// 判断要保守：主页面明确写着“暂无内容”，并且没有题目、没有提交按钮、没有图文框架、没有视频，
// 免得把“题目还在加载”的正常测验误判成空节直接跳过。
function quizSectionLooksEmpty() {
try {
if (!pageShowsNoContent()) return false;
if (courseDocuments().some((doc) => findQuizSubmit(doc))) return false;
if (extractQuestions().length) return false;
if (contentFrameDocs().length) return false;
if (app._findAllVideos().length) return false;
return true;
} catch (_) {
return false;
}
}
// 停滞自检（app 的方法）判断“视频是否在播”“有几篇图文”时也要用这两个探测函数，
// 它们只在这个作用域里，所以挂到 app 上，自检里用 this._visibleVideoState() / this._contentFrameDocs()
app._visibleVideoState = visibleVideoState;
app._contentFrameDocs = contentFrameDocs;

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

// —— 视频任务点还在加载 ——
// 切换小节时，播放器框架和“任务点/观看时长”标题通常先出来，<video> 要再等一两秒。
// 这段时间如果按“纯图文”去滚内容区（本页的“知识点”也会被当成图文），视频就会一直停着，
// 要等人手动点一下才动。所以先认出“这是视频任务点、视频还没就绪”，等它加载。
function videoTaskLoading() {
try {
// 视频元素已经在页面里，只是还没布局好或还没加载出画面
if (typeof app._findAllVideos === 'function' && app._findAllVideos(true).length) return true;
} catch (_) { /* 忽略 */ }
for (const doc of courseDocuments()) {
try {
// 外层页面的视频任务标题栏：只有视频任务点才会出现“观看时长”
if (doc === document) {
const pageText = clean(doc.body ? doc.body.innerText : '');
if (pageText.length <= 50000 && /观看时长|视频任务点/.test(pageText)) return true;
}
const frames = Array.from(doc.querySelectorAll('iframe'));
const playerFrame = frames.some((frame) => {
const src = frame.getAttribute('src') || '';
if (!/ananas\/modules\/video|modules\/video\/index/i.test(src)) return false;
try { return frame.getClientRects().length > 0; } catch (_) { return false; }
});
if (playerFrame) return true;
} catch (_) { /* 跨域框架读不到就跳过 */ }
}
return false;
}

// 等视频任务点加载：最多等 15 秒，等不到就交回原流程（滚动图文/切节），绝不死等。
// 同一节只等一次，避免“等 15 秒 → 滚图文 → 再等 15 秒”来回空转。
app._waitVideoTaskLoading = function () {
if (stopped || this._destroyed) return false;
if (!videoTaskLoading()) {
this._videoLoadWaitSince = 0;
return false;
}
const now = Date.now();
let section = '';
try { section = activeSectionKey(); } catch (_) { section = ''; }
if (section && this._videoWaitGaveUpSection === section) {
this._videoLoadWaitSince = 0;
return false;
}
if (!this._videoLoadWaitSince) this._videoLoadWaitSince = now;
if (now - this._videoLoadWaitSince >= 15000) {
this._videoLoadWaitSince = 0;
this._videoWaitGaveUpSection = section;
console.warn('%c视频任务点等了 15 秒仍没加载出视频，先处理页面上的其它内容', 'color:#FF9800');
return false;
}
if (!this._videoWaitLoggedAt || now - this._videoWaitLoggedAt > 8000) {
this._videoWaitLoggedAt = now;
console.log('%c检测到视频任务点还在加载，先等视频就绪（暂不滚动图文）', 'color:#2196F3');
}
this._isPlaying = false;
this._clearCheckInterval();
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 1200);
return true;
};

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
// 页面明确写着“未达到及格线，请重做”：这一份还要重做，不管显示什么成绩都不算完成
if (quizFailureShown()) return false;
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
// docTaskBusy / docTaskBusySince / docTaskWakeAt 定义在模块级（app 的停滞自检也要读写）
let docTaskSignature = '';
let docTaskHandledAt = 0;
// —— 完成情况保险：一个任务点里常叠着多篇图文，平台是逐篇记完成的 ——
// 记下每节图文的阅读结果，切到下一节时回头核对目录有没有打勾，没打勾就回去补做。
const docProgress = new Map();
let docLastSection = '';
let docAuditAt = 0;
let docPageAttempts = 0;
let docPageAttemptsSignature = '';
// —— 扫描结果缓存 ——
// 找图文内容要读 innerText、逐个查元素样式，这些都会触发整页重排。
// play() 每 1~2 秒就会走一遍，页面上元素一多，Edge 就会明显卡顿，
// 所以同一瞬间的重复扫描直接复用结果（几百毫秒的窗口，不影响判断）。
let contentDocsCache = { at: 0, items: [] };
let scrollablesCache = { at: 0, key: '', list: [] };
const docIdMap = new WeakMap();
let docIdSeq = 0;
function docIdOf(doc) {
if (!doc) return 0;
if (!docIdMap.has(doc)) docIdMap.set(doc, ++docIdSeq);
return docIdMap.get(doc);
}
function invalidateDocumentScan() {
contentDocsCache = { at: 0, items: [] };
scrollablesCache = { at: 0, key: '', list: [] };
}

function contentFrameDocs() {
const cachedAt = contentDocsCache.at;
if (cachedAt && Date.now() - cachedAt < 500) return contentDocsCache.items;
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
contentDocsCache = { at: Date.now(), items };
return items;
}

function documentScrollables(docs) {
const now = Date.now();
const key = docs.map((item) => docIdOf(item.doc)).join('-');
if (scrollablesCache.at && scrollablesCache.key === key && now - scrollablesCache.at < 1500) return scrollablesCache.list;
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
scrollablesCache = { at: now, key, list };
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

// 滚动过程中的心跳：还在滚就刷新占用时间。
// “图文占用超过 20 秒判定卡住”只有在真的没有滚动进展时才成立，
// 不会把长篇/多篇图文这种正常但耗时的情况误判成卡死。
function noteDocTaskProgress() {
if (docTaskBusy) docTaskBusySince = Date.now();
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
noteDocTaskProgress();
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
// 滚动过程中视频才加载出来：视频优先，立刻停下来交给视频流程
if (pageHasUnfinishedVideo()) break;
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
noteDocTaskProgress();
const after = documentScrollables(contentFrameDocs());
const allBottom = after.length > 0 && after.every(containerAtBottom);
if (documentCompletionShown()) sawCompletion = true;
const signature = after.map((entry) => `${entry.el.scrollTop}:${entry.el.scrollHeight}:${entry.el.clientHeight}`).join('|');
if (signature === lastSignature) stableRounds++; else stableRounds = 0;
lastSignature = signature;
console.log(`%c第 ${rounds} 轮阅读滚动：滚动区 ${after.length} 个，全部到底=${allBottom}，完成标记=${sawCompletion}`, 'color:#607D8B');
if (typeof app !== 'undefined' && app && typeof app._noteProgress === 'function') app._noteProgress();
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

// —— 播放线路重试 ——
// 视频加载失败时，播放器会显示“视频因格式不支持或者服务器或网络的问题无法加载。
// 您可以尝试其他线路：公网1 公网2”。这种时候点什么都没用，必须去点那条备用线路。
function videoLoadErrorShown() {
for (const doc of courseDocuments()) {
let text = '';
try { text = doc.body ? String(doc.body.innerText || doc.body.textContent || '') : ''; } catch (_) { text = ''; }
if (!text || text.length > 30000) continue;
if (/尝试其他线路|视频因格式不支持|视频无法加载|视频加载失败|该视频无法播放/.test(text)) return true;
}
return false;
}

// 找出“公网1 / 公网2 / 线路1”这类可点击的备用线路，只取最内层节点，避免点到外层容器
function alternativeLineTargets() {
const targets = [];
const seen = new Set();
for (const doc of courseDocuments()) {
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('a,button,li,label,span,p,div,strong,em')); } catch (_) { nodes = []; }
for (const node of nodes) {
let text = '';
try { text = clean(node.innerText || node.textContent || ''); } catch (_) { text = ''; }
if (!text || text.length > 14) continue;
if (!/^(公网|线路|备用|备选|专线)\s*[0-9一二三四五六七八九]?$/.test(text)) continue;
if (seen.has(node)) continue;
seen.add(node);
let hasInner = false;
try {
hasInner = Array.from(node.children).some((child) => clean(child.innerText || child.textContent || '') === text);
} catch (_) { hasInner = false; }
if (hasInner) continue;
let shown = false;
try { shown = visible(node); } catch (_) { shown = false; }
if (!shown) continue;
targets.push({ el: node, text });
}
}
return targets;
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

// 整页正文的指纹：只比对开头几十个字很容易把“同系列的两篇图文”当成同一页，
// 那样第二篇会被直接跳过，所以这里按全文长度 + 全文哈希 + 图片数一起算。
function textFingerprint(text) {
const value = String(text || '');
let hash = 5381;
for (let i = 0; i < value.length; i++) hash = ((hash * 33) ^ value.charCodeAt(i)) >>> 0;
return `${value.length}-${hash.toString(36)}`;
}

function documentPageSignature(docs) {
const parts = [];
for (const item of docs) parts.push(`${textFingerprint(item.text)}/${item.images}`);
return `${cardsFrameSrcs()}#${parts.join('||')}`;
}

// 左侧目录里每一节（含完成标记），用于核对“这一节到底打没打勾”
function catalogItems() {
const items = [];
try {
const root = document.querySelector('#coursetree') || document;
for (const node of root.querySelectorAll('.posCatalog_select')) {
if (node.classList.contains('firstLayer')) continue;
const nameEl = node.querySelector('.posCatalog_name');
const label = clean((nameEl && (nameEl.getAttribute('title') || nameEl.textContent)) || node.textContent);
if (!label || label.length > 80) continue;
if (items.some((item) => item.label === label)) continue;
let done = false;
try { done = Boolean(node.querySelector('.icon_Completed')); } catch (_) { done = false; }
items.push({ label, done, el: node, active: node.classList.contains('posCatalog_active') });
}
} catch (_) { /* 目录结构变化时忽略 */ }
return items;
}

// 小节标识优先用目录节点的标题，保证和后面核对时用的是同一个键
function activeSectionKey() {
try {
const entry = catalogItems().find((item) => item.active);
if (entry) return entry.label;
} catch (_) { /* 忽略 */ }
try {
return typeof activeCatalogLabel === 'function' ? clean(activeCatalogLabel()) : '';
} catch (_) { return ''; }
}

function catalogSectionDone(label) {
const target = clean(label);
if (!target) return null;
const item = catalogItems().find((entry) => entry.label === target);
return item ? item.done : null;
}

// 只有目录里已经出现过“打勾”的节点，才能相信“没打勾＝没完成”；
// 否则说明这个页面的完成标记不是这么显示的，不要拿它去做回跳判断。
function catalogMarkerUsable() {
return catalogItems().some((item) => item.done);
}

// 这一节是不是已经全部做完了。
// 只认目录里“整节打勾”：平台的勾代表这一节的所有任务点（多个视频、多篇图文、视频+测验混排）都完成了；
// 页面上那句“任务点已完成”只代表当前显示的那一个任务点，多任务点的小节里它先亮也不能算整节完成。
// 目录里根本没有勾这个标记时（catalogMarkerUsable 为假）一律不信，避免误跳。
let doneSectionSkipped = { label: '', at: 0 };
function sectionAlreadyCompleted() {
if (!catalogMarkerUsable()) return false;
const label = activeSectionKey();
if (!label) return false;
if (catalogSectionDone(label) !== true) return false;
// 同一节 60 秒内只跳一次：万一“下一节”没点动，也别原地疯狂重试
const now = Date.now();
if (doneSectionSkipped.label === label && now - doneSectionSkipped.at < 60000) return false;
doneSectionSkipped = { label, at: now };
return true;
}
app._sectionAlreadyCompleted = sectionAlreadyCompleted;

// 当前显示的任务点编号（内容框架 src 里的 num）：这一节里的第几个任务点。
// 用它给“任务点已完成”的跳过做冷却，同一节同一个任务点只跳一次。
function currentTaskPointNum() {
try {
const frame = displayedCardsFrame();
if (!frame) return '';
return new URL(frame.getAttribute('src'), location.href).searchParams.get('num') || '';
} catch (_) { return ''; }
}

// 这个框架里是不是已经有平台打上的“任务点已完成”标记
function docShowsTaskPointDone(doc) {
if (!doc || !doc.body) return false;
let text = '';
try { text = clean(doc.body.innerText || doc.body.textContent || ''); } catch (_) { return false; }
if (!text || text.length > 30000) return false;
return /任务点已完成|视频任务点已完成|视频已完成/.test(text);
}

// 页面上有没有“平台已标记完成”的视频任务点（内容区那行绿字，不是目录里的勾）
function completedVideoTaskPointShown() {
try {
for (const doc of courseDocuments()) {
let hasVideo = false;
try { hasVideo = Boolean(doc.querySelector('video')); } catch (_) { hasVideo = false; }
if (hasVideo && docShowsTaskPointDone(doc)) return true;
}
} catch (_) { /* 跨域或页面正在重建 */ }
return false;
}

// 当前这段视频所在的任务点，平台是不是已经标记成“任务点已完成”。
// 一个任务点就是一个内容框架：视频（含同框架里的多个分段）和它附带的图文都在这个框架里，
// 框架里出现这句标记，说明整个任务点平台已经记为完成——再从头播一遍毫无意义。
// 只认视频自己所在的框架：别的框架里的完成标记属于别的任务点，不能拿来跳这一段。
// 整节完成的判断在 sectionAlreadyCompleted；这里管的是“这个任务点已完成、但这一节还有别的任务点（比如章节测验）”。
// 同一节同一个任务点 60 秒内只跳一次：万一“下一节”没点动或被平台拦回来，就回去正常播放，别原地打转。
let doneTaskPointSkipped = { key: '', at: 0 };
function videoTaskPointCompleted(el) {
if (!el) return false;
let doc = null;
try { doc = el.ownerDocument; } catch (_) { doc = null; }
if (!docShowsTaskPointDone(doc)) return false;
const key = `${activeSectionKey()}|${currentTaskPointNum()}`;
const now = Date.now();
if (doneTaskPointSkipped.key === key && now - doneTaskPointSkipped.at < 60000) return false;
doneTaskPointSkipped = { key, at: now };
return true;
}
app._videoTaskPointCompleted = videoTaskPointCompleted;

function noteDocumentRead(label, verified) {
const key = clean(label);
if (!key) return;
const state = docProgress.get(key) || { attempts: 0, verified: false, redos: 0, warned: false, at: 0 };
state.attempts += 1;
state.verified = state.verified || Boolean(verified);
state.at = Date.now();
docProgress.set(key, state);
docLastSection = key;
}

function goBackToSection(label) {
const item = catalogItems().find((entry) => entry.label === label);
if (!item) return false;
const clickable = item.el.querySelector('.posCatalog_name') || item.el;
const state = docProgress.get(label);
if (state) state.redos += 1;
const redos = state ? state.redos : 1;
docAuditAt = Date.now();
docLastSection = '';
// 清掉“这页读过了”的标记，回去以后要老老实实重读，而不是直接又点下一节
docTaskSignature = '';
docPageAttempts = 0;
docPageAttemptsSignature = '';
invalidateDocumentScan();
console.log(`%c完成情况保险：目录里“${label}”还没打勾，返回该节补做，避免漏做（第 ${redos} 次）`, 'color:#FF9800');
app._nextUnitPending = false;
app._videoEl = null;
app._quizVideo = null;
app._isPlaying = false;
app._allDoneChecks = 0;
if (typeof app._clearCheckInterval === 'function') app._clearCheckInterval();
try {
clickable.click();
} catch (_) {
return false;
}
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 3500);
return true;
}

// 切到新小节时核对上一个图文小节：读过但没看到完成标记、目录也没打勾，就回去补做
function docProgressAudit() {
if (stopped) return false;
if (docTaskBusy) return false;
if (!docLastSection) return false;
if (Date.now() - docAuditAt < 6000) return false;
let label = '';
try { label = activeSectionKey(); } catch (_) { label = ''; }
if (!label || label === docLastSection) return false;
// 视频还在播、或者已经进入测验页时不回跳，等这一段结束再核对
let playing = false;
try { playing = typeof visibleVideoState === 'function' && visibleVideoState().playing; } catch (_) { playing = false; }
if (playing) return false;
if (typeof app._isChapterTest === 'function' && app._isChapterTest()) return false;
if (app._videoQuizActive || app._videoQuizPending) return false;
const state = docProgress.get(docLastSection);
if (!state || state.verified) {
docLastSection = label;
return false;
}
if (state.redos >= 2) {
if (!state.warned) {
state.warned = true;
console.warn(`%c“${docLastSection}”已回补 2 次仍未确认完成，先继续后面的内容，结束后请手动检查这一节`, 'color:#F44336');
}
docLastSection = label;
return false;
}
if (!catalogMarkerUsable()) return false;
if (catalogSectionDone(docLastSection) !== false) {
docLastSection = label;
return false;
}
return goBackToSection(docLastSection);
}

app._handleDocumentTask = async function () {
if (stopped || this._destroyed) return false;
if (docTaskBusy) {
// 滚动任务正在进行，避免重复触发；稍后再确认下一步（限制排队，避免定时器堆积）
const busyFor = docTaskBusySince ? Date.now() - docTaskBusySince : 0;
if (busyFor > 20000) {
// 滚动流程被异常卡住（页面框架被替换、平台报错等）：解除占用，重新从头识别本页
docTaskBusy = false;
docTaskBusySince = 0;
console.warn(`%c图文滚动占用已超过 ${Math.round(busyFor / 1000)} 秒，判定为卡住，已自动解除并重新识别本页`, 'color:#FF9800');
} else {
if (!docTaskWakeAt || Date.now() - docTaskWakeAt > 3000) {
docTaskWakeAt = Date.now();
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 1500);
}
return true;
}
}
// 本页还有没播完的视频时不抢活，交给视频流程；视频播完会再回到这里
if (pageHasUnfinishedVideo()) return false;
if (this._isChapterTest()) return false;
const docs = contentFrameDocs();
if (!docs.length) return false;
const signature = documentPageSignature(docs);
if (docPageAttemptsSignature !== signature) {
docPageAttemptsSignature = signature;
docPageAttempts = 0;
}
const samePage = Boolean(signature && signature === docTaskSignature);
const scrollables = documentScrollables(docs);
const sectionDone = documentCompletionShown();
const pendingScroll = scrollables.some((entry) => !containerAtBottom(entry));
let alreadyRead = samePage && (!pendingScroll || sectionDone);
if (samePage && pendingScroll && !sectionDone) {
// 同一个任务点里又渲染出了后面的图文：接着读，绝不能在这里点“下一节”把它跳过去
if (docPageAttempts >= 4) {
console.warn('%c同一处图文反复滚动仍未确认完成，先进入下一步；完成情况保险会在下一节回头核对', 'color:#FF9800');
alreadyRead = true;
} else {
docPageAttempts += 1;
console.log(`%c本页还有没读到底的图文（可能是刚渲染出的下一篇），继续补读（第 ${docPageAttempts} 次）`, 'color:#2196F3');
}
} else if (samePage && pendingScroll && sectionDone) {
console.log('%c本页图文已确认完成（没到底只是阅读器回滚到顶部），跳过重复阅读', 'color:#607D8B');
}
docTaskBusy = true;
docTaskBusySince = Date.now();
if (!samePage) docTaskSignature = signature;
docTaskHandledAt = Date.now();
this._isPlaying = false;
this._noVideoRetryTimes = 0;
this._clearCheckInterval();
const startFrameSrcs = cardsFrameSrcs();
// 先记下“现在读的是哪一节”，滚动过程中平台自动跳节也不会记到下一节头上
const sectionKey = activeSectionKey();
let verified = sectionDone;
try {
const totalChars = docs.reduce((sum, item) => sum + item.text.length, 0);
const totalImages = docs.reduce((sum, item) => sum + item.images, 0);
let read = { rounds: 0, containers: scrollables.length, sawCompletion: sectionDone };
if (alreadyRead) {
console.log('%c本页图文已经滚动到底，跳过重复阅读，检查是否还有视频/下一步', 'color:#607D8B');
noteDocumentRead(sectionKey, verified);
} else {
console.log(`%c检测到阅读/图文任务点（约 ${totalChars} 字，${totalImages} 张图），开始滚动到最底部`, 'color:#2196F3');
read = await readThroughDocuments();
// 视频在滚动过程中才就绪：先播视频，剩下的图文等视频播完再补（别把视频一直晾着）
if (pageHasUnfinishedVideo()) {
console.log('%c本页视频已就绪，先播放视频，图文稍后继续', 'color:#4CAF50');
app._nextUnitPending = false;
setTimeout(() => { if (!stopped && !app._destroyed) app.play(); }, 600);
return true;
}
verified = read.sawCompletion || documentCompletionShown();
if (!verified) {
console.log('%c暂未看到完成标记，在底部再轻微滚动一次以确保触发平台检测', 'color:#FF9800');
for (const entry of documentScrollables(contentFrameDocs())) {
if (stopped) return true;
await nudgeToBottom(entry);
}
verified = await waitForDocumentCompletion(5000);
}
// 多篇图文里，后面那篇可能滚到下面才渲染出来：读完再核对一次内容有没有变多
let latestSignature = documentPageSignature(contentFrameDocs());
for (let extra = 0; extra < 2 && !stopped && latestSignature !== signature; extra++) {
console.log('%c滚动后本页又出现了新的图文内容，继续补读', 'color:#2196F3');
const more = await readThroughDocuments();
read.rounds += more.rounds;
read.containers = Math.max(read.containers, more.containers);
if (more.sawCompletion) verified = true;
if (!verified) verified = await waitForDocumentCompletion(3000);
const nextSignature = documentPageSignature(contentFrameDocs());
if (nextSignature === latestSignature) break;
latestSignature = nextSignature;
}
read.sawCompletion = verified;
docTaskSignature = latestSignature;
noteDocumentRead(sectionKey, verified);
if (typeof app._noteProgress === 'function') app._noteProgress();
app._stallRestarts = 0;
if (verified) console.log(`%c阅读任务点已完成（共 ${read.rounds} 轮，覆盖 ${read.containers} 个滚动区），准备进入下一学习步骤`, 'color:#4CAF50');
else console.warn(`%c已滚动 ${read.rounds} 轮、覆盖 ${read.containers} 个滚动区，暂未收到平台完成标记，仍按已完成继续切换（下一节会回头核对是否漏做）`, 'color:#FF9800');
}
docTaskHandledAt = Date.now();
} catch (error) {
console.warn('阅读任务点滚动失败，已跳过本次滚动:', error && error.message ? error.message : error);
} finally {
docTaskBusy = false;
docTaskBusySince = 0;
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

// 被“任务点未完成”弹窗退回，说明这一页没做完整：清掉“已读过”的标记，回去重新读，
// 否则会照着旧标记直接再点一次“下一节”，永远补不上漏掉的那一篇。
app._resetDocReading = function () {
docTaskSignature = '';
docTaskHandledAt = 0;
docPageAttempts = 0;
docPageAttemptsSignature = '';
invalidateDocumentScan();
if (docLastSection) {
const state = docProgress.get(docLastSection);
if (state) {
state.verified = false;
state.attempts = 0;
}
}
};

app._docProgressAudit = docProgressAudit;
app._goBackToSection = goBackToSection;

// 视频加载不出来时自动点备用线路（公网1/公网2），而不是干等着什么也不做
app._retryAlternateVideoLine = function (reason) {
if (stopped || this._destroyed) return false;
let errorShown = false;
try { errorShown = videoLoadErrorShown(); } catch (_) { errorShown = false; }
if (!errorShown) return false;
const now = Date.now();
// 换线路后播放器要重新加载视频，同一节里别点得太急
if (now - (this._lineRetryAt || 0) < 5000) return false;
let section = '';
try { section = activeSectionKey(); } catch (_) { section = ''; }
if (section && section !== this._lineSection) {
this._lineSection = section;
this._lineTried = new Set();
this._lineAttempts = 0;
this._lineGaveUpAt = 0;
}
if (!this._lineTried) this._lineTried = new Set();
if ((this._lineAttempts || 0) >= 6) {
if (!this._lineGaveUpAt || now - this._lineGaveUpAt > 60000) {
this._lineGaveUpAt = now;
console.warn('%c备用线路已经试了 6 次，视频还是加载不出来；先按原流程处理，稍后再回来试', 'color:#FF9800');
}
return false;
}
let targets = [];
try { targets = alternativeLineTargets(); } catch (_) { targets = []; }
if (!targets.length) return false;
// 多条线路轮着试：先点还没试过的，都试过了再从第一条重新开始
let target = targets.find((item) => !this._lineTried.has(item.text));
if (!target) {
this._lineTried.clear();
target = targets[0];
}
this._lineTried.add(target.text);
this._lineAttempts = (this._lineAttempts || 0) + 1;
this._lineRetryAt = now;
console.log(`%c视频加载失败${reason ? `（${reason}）` : ''}，自动切换播放线路：${target.text}（第 ${this._lineAttempts} 次）`, 'color:#2196F3');
try {
target.el.click();
} catch (_) {
try { target.el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window })); } catch (_) {}
}
this._noteProgress();
setTimeout(() => { if (!stopped && !this._destroyed) this.play(); }, 3000);
return true;
};

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

// 判断题常见的写法是“正确/错误”“对/错”“√/×”，选项没有 A/B 字母。
// 按出现顺序映射成 A=正确、B=错误，后面的选答案和 AI 提示都按字母处理。
function judgeOptionElements(card) {
const pairs = [['正确', '错误'], ['对', '错'], ['√', '×'], ['是', '否']];
for (const [yes, no] of pairs) {
let yesEl = null;
let noEl = null;
let nodes = [];
try { nodes = Array.from(card.querySelectorAll('span,div,label,li,p,b,i,strong,a,button')); } catch (_) { return []; }
for (const el of nodes) {
let text = '';
try { text = clean(el.textContent); } catch (_) { text = ''; }
if (text !== yes && text !== no) continue;
if (!visible(el)) continue;
// 只取最里层：外层容器也带着同一句话
let innerSame = false;
try {
innerSame = Array.from(el.children || []).some((child) => clean(child.textContent) === text);
} catch (_) { innerSame = false; }
if (innerSame) continue;
if (text === yes && !yesEl) yesEl = el;
if (text === no && !noEl) noEl = el;
}
if (yesEl && noEl) {
return [
{ letter: 'A', text: yes, element: yesEl },
{ letter: 'B', text: no, element: noEl },
];
}
}
return [];
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
// 判断题：没有字母，“正确/错误”两个选项
const judge = judgeOptionElements(card);
if (judge.length >= 2) return judge;
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

// onlyDocs：只在这些框架里找题（识别“能不能重新作答”时用，避免把隐藏框架里
// 上一份成绩页的题目混进来，题量永远对不上）
function extractQuestions(onlyDocs) {
const questions = [];
for (const doc of (Array.isArray(onlyDocs) ? onlyDocs : courseDocuments())) {
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
// 同名题型标签重复出现不算“爬到两道题”，只有出现不同题型才停
if (distinctKindTags(cardText, kindPattern).size > 1) break;
options = optionElements(card);
if (options.length >= 2 && options.length <= 8) break;
}
if (!card || options.length < 2 || options.length > 8 || seenCards.has(card)) continue;
seenCards.add(card);
const full = card.innerText || '';
const firstOption = full.search(/(?:^|\n)\s*A\s*(?:[.、．]|\S)/);
const title = clean(firstOption >= 0 ? full.slice(0, firstOption) :
(node.parentElement.innerText || full))
.replace(/^\d+\s*/, '').replace(new RegExp(kindPattern.source, 'g'), '').trim();
if (!title || title.length > 500 || options.some((option) => !option.text || option.text.length > 500)) continue;
questions.push({ kind, title, options, card, doc });
}
}
return questions;
}

// 题型标签缺失、重复或换了写法时，按“选项输入框”的结构把题目补回来：
// 每道选择题都有 2-8 个 radio/checkbox，从输入框往上找到刚好包住这一组选项的容器。
// 题型优先读标签，读不出来就按结构判断（对/错两项是判断题，多个 checkbox 是多选题）。
// 这一步只在正常识别题量不够时兜底，不参与常规识别，避免把页头搜索框之类误当成题目。
function structuralKindOf(card, options) {
const texts = options.map((option) => clean(option.text));
if (texts.length === 2 && texts.every((text) => /^(对|错|正确|错误|√|×|T|F|是|否)$/i.test(text))) return '判断题';
try {
if (card.querySelectorAll('input[type="checkbox"]').length >= 2) return '多选题';
} catch (_) { /* 忽略 */ }
return '单选题';
}

function structuralQuizQuestions(onlyDocs) {
const found = [];
for (const doc of (Array.isArray(onlyDocs) ? onlyDocs : courseDocuments())) {
if (!doc.body) continue;
const seenCards = new Set();
let inputs = [];
try { inputs = Array.from(doc.querySelectorAll('input[type="radio"],input[type="checkbox"]')); } catch (_) { continue; }
for (const input of inputs) {
if (!visible(input)) continue;
let card = input.parentElement;
let options = [];
for (let depth = 0; card && card !== doc.body && depth < 9; depth++, card = card.parentElement) {
const cardText = clean(card.innerText);
// 只有出现不同题型标签时才算爬到多道题外层；同名标签重复渲染不算
if (distinctKindTags(cardText, kindPattern).size > 1) { options = []; break; }
options = optionElements(card);
if (options.length >= 2 && options.length <= 8) break;
}
if (!card || card === doc.body || options.length < 2 || options.length > 8 || seenCards.has(card)) continue;
seenCards.add(card);
const full = String(card.innerText || '');
// 一道题的容器里只该有一个题号；能数到多个题号说明这个容器装了好几道题，不能整块当成一题。
// 明确是题目卡片（TiMu/Zy_）的例外：题干里可能自带“1. 2.”这种列举
const questionBox = /TiMu|Zy_|timu|question|exercise/i.test(`${card.className || ''} ${card.id || ''}`);
if (!questionBox && (full.match(/(?:^|\n)\s*\d+\s*[.、．]/g) || []).length > 1) continue;
const kind = clean(full).match(kindPattern)?.[1] || structuralKindOf(card, options);
const firstOption = full.search(/(?:^|\n)\s*A\s*(?:[.、．]|\S)/);
const title = clean(firstOption >= 0 ? full.slice(0, firstOption) : full)
.replace(/^\d+\s*/, '').replace(new RegExp(kindPattern.source, 'g'), '').trim();
if (!title || title.length > 500 || options.some((option) => !option.text || option.text.length > 500)) continue;
found.push({ kind, title, options, card, doc });
}
}
return found;
}

// —— 填空题/简答题 ——
// 这两类题没有选项，靠“输入框”识别。卷面上不一定每题都带【填空题】标签，
// 所以先按标签找，再按“输入框 + 题干”兜底找，两边用同一批输入框去重。
const TEXT_KINDS_SOURCE = '填空题|简答题|论述题|名词解释';
const textKindPattern = new RegExp(`[\\[【](${TEXT_KINDS_SOURCE})[\\]】]`);
const TEXT_INPUT_SELECTOR = 'input[type="text"],input[type="search"],input:not([type]),textarea,[contenteditable="true"],[contenteditable=""],[role="textbox"]';

// 新版学习通的填空题常被做成富文本编辑器：可编辑正文在同源 iframe 里（UEditor），
// 页面上只看得到一个空框，querySelector 扫不到 input。这里把这种 iframe 也当成一个“空”
function editorFrameDetails(frame) {
const doc = frame.contentDocument;
const id = frame.id || (frame.closest ? (frame.closest('[id]') || {}).id : '') || '';
let UE = null;
try {
const win = frame.ownerDocument.defaultView;
UE = (win && win.UE) || (win && win.parent && win.parent.UE) || null;
} catch (_) { UE = null; }
let editor = null;
if (UE && typeof UE.getEditor === 'function') {
for (const key of [id, `ueditor_${id}`, id.replace(/^ueditor_/, '')]) {
try { editor = editor || UE.getEditor(key); } catch (_) { /* 忽略 */ }
}
}
return { doc, id, UE, editor };
}

function editorFramesWithin(root) {
let frames = [];
try { frames = Array.from(root.querySelectorAll('iframe')); } catch (_) { return []; }
return frames.filter((frame) => {
if (!visible(frame)) return false;
let doc = null;
try { doc = frame.contentDocument; } catch (_) { return false; }
if (!doc || !doc.body) return false;
try {
if (doc.body.isContentEditable || doc.body.getAttribute('contenteditable') === 'true' || doc.body.getAttribute('contenteditable') === '') return true;
return Boolean(doc.querySelector('[contenteditable="true"],[contenteditable=""],[role="textbox"]'));
} catch (_) { return false; }
});
}

function editorFrameValue(frame) {
const { doc, editor } = editorFrameDetails(frame);
try {
if (editor && typeof editor.getContentTxt === 'function') return clean(editor.getContentTxt());
} catch (_) { /* 忽略 */ }
try { return clean(doc.body.innerText || doc.body.textContent); } catch (_) { return ''; }
}

function writeEditorFrame(frame, value) {
const { doc, editor } = editorFrameDetails(frame);
let done = false;
try {
if (editor && typeof editor.setContent === 'function') {
editor.setContent(value);
done = true;
}
if (editor && typeof editor.fireEvent === 'function') editor.fireEvent('contentChange');
} catch (_) { done = false; }
if (!done) {
try {
doc.body.innerHTML = '';
doc.body.textContent = value;
} catch (_) { /* 忽略 */ }
}
for (const target of [doc.body, frame]) {
for (const type of ['input', 'change', 'keyup']) dispatchTextEvent(target, type);
}
}

function fillableElements(root) {
if (!root || typeof root.querySelectorAll !== 'function') return [];
let list = [];
try { list = Array.from(root.querySelectorAll(TEXT_INPUT_SELECTOR)); } catch (_) { return []; }
// 只有题目容器里写着“第N空”的，才把 disabled/readonly 的框也当可填（有些平台重做时
// 输入框是灰的，去掉属性就能写）；整页扫描时不放宽，免得把搜索框之类的误当成填空
let blankLabeled = false;
try {
const scope = root.body || root;
const scopeText = String(scope.innerText || scope.textContent || '');
blankLabeled = /第\s*[0-9一二三四五六七八九十]+\s*空/.test(scopeText);
} catch (_) { blankLabeled = false; }
const fields = list.filter((el) => {
if (!visible(el)) return false;
// 目录/页头搜索框也是 input[type=text]，它不是题目里的空，绝不能算成“填空输入框”
if (el.tagName === 'INPUT' && searchLikeInput(el)) return false;
if ((el.disabled || el.readOnly === true) && !blankLabeled) return false;
if (el.tagName === 'INPUT') {
const type = String(el.type || '').toLowerCase();
if (type && type !== 'text' && type !== 'search') return false;
}
return true;
});
for (const frame of editorFramesWithin(root)) fields.push(frame);
// 同一题里既有普通输入框又有富文本编辑框时，按页面上的先后顺序对应第1空、第2空
fields.sort((a, b) => {
if (a === b) return 0;
try {
if (a.ownerDocument === b.ownerDocument) {
const pos = a.compareDocumentPosition(b);
if (pos & 4) return -1;
if (pos & 2) return 1;
}
} catch (_) { /* 忽略 */ }
return 0;
});
return fields;
}

function textQuestionTitle(card, kind) {
let text = '';
try { text = clean(card.innerText || card.textContent); } catch (_) { return ''; }
return text
.replace(new RegExp(textKindPattern.source, 'g'), '')
.replace(/^\s*\d+\s*[.、．:：]?\s*/, '')
// 成绩页会把“我的答案/正确答案/答案解析”拼在题干后面：题干只留到这些标记之前，
// 否则同一道题在作答页和成绩页会被当成两道，纠错记忆对不上
.replace(/\s*(?:我的答案|你的答案|正确答案|答案解析|得分|回答正确|回答错误|第\s*\d+\s*空)\s*[：:][\s\S]*$/, '')
.trim()
.slice(0, 1000);
}

function isQuizTextDocument(doc) {
let bodyText = '';
try { bodyText = clean(doc.body.innerText || doc.body.textContent); } catch (_) { return false; }
if (/题量\s*[:：]\s*\d+/.test(bodyText)) return true;
if (/我的答案\s*[：:]|正确答案\s*[：:]/.test(bodyText)) return true;
try { return Boolean(findQuizSubmit(doc)); } catch (_) { return false; }
}

// 输入框所在的题号容器：从输入框往上找，跳过只有“第1空：”这种标签的小盒子
function textQuestionCardFor(input) {
let card = input.parentElement;
for (let depth = 0; card && depth < 8; card = card.parentElement) {
const doc = input.ownerDocument;
if (!doc || card === doc.body) break;
let inputs = [];
try { inputs = fillableElements(card); } catch (_) { inputs = []; }
if (inputs.length > 12) return null;
if (inputs.length && optionElements(card).length < 2) {
let text = '';
let raw = '';
try { text = clean(card.innerText); } catch (_) { text = ''; }
try { raw = String(card.innerText || ''); } catch (_) { raw = ''; }
// clean() 会把换行压成空格，题号判断必须用原始文字，否则永远数不到“另一道题”的题号
const questionMarks = (raw.match(/(?:^|\n)\s*\d+\s*[.、．]/g) || []).length;
if (questionMarks <= 1 && text.length >= 6) return card;
}
}
return null;
}

// 没有【填空题】标签时，只能靠输入框兜底识别。兜底必须保守：目录搜索框挂在整页容器里，
// 往上爬到卷面根节点时文字也“够长”，以前会凭空多出一道填空题，整卷题量就永远对不上。
// 只认真正的题目容器：写着“第N空”，或者容器本身是题目卡片（TiMu/Zy_/question 之类）
function textQuestionCardLooksReal(card) {
if (!card) return false;
const doc = card.ownerDocument;
if (!doc || card === doc.body) return false;
let raw = '';
try { raw = String(card.innerText || ''); } catch (_) { return false; }
if (!raw.trim() || raw.length > 2400) return false;
if (/第\s*[0-9一二三四五六七八九十]+\s*空/.test(raw)) return true;
const hint = `${card.className || ''} ${card.id || ''}`;
let questionBox = /TiMu|Zy_|timu|question|exercise/i.test(hint);
if (!questionBox && card.closest) {
try { questionBox = Boolean(card.closest('.TiMu,[class*="TiMu"],[class*="Zy_"],[class*="timu"],[class*="question"],[class*="Question"]')); } catch (_) { questionBox = false; }
}
if (!questionBox) return false;
// 整卷容器（同时写着“题量：N”和多个题号）不是一道题
const marks = (raw.match(/(?:^|\n)\s*\d+\s*[.、．]/g) || []).length;
if (/题量\s*[:：]\s*\d+/.test(raw) && marks > 1) return false;
return true;
}

let quizBlankDiagAt = 0;
function taggedTextQuestions(doc, usedInputs) {
const found = [];
const seenCards = new Set();
const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
let node;
while ((node = walker.nextNode())) {
const match = clean(node.textContent).match(textKindPattern);
if (!match || !visible(node.parentElement)) continue;
const kind = match[1];
let card = node.parentElement;
let chosen = null;
let blanks = [];
let suspect = node.parentElement;
for (let depth = 0; card && depth < 9; depth++, card = card.parentElement) {
suspect = card;
let cardText = '';
try { cardText = clean(card.innerText); } catch (_) { cardText = ''; }
if (distinctKindTags(cardText, textKindPattern).size > 1) break;
if (optionElements(card).length >= 2) break;
const inputs = fillableElements(card);
if (!inputs.length) continue;
if (inputs.length > 12) break;
chosen = card;
blanks = inputs;
break;
}
if (!chosen) {
// 看到【填空题】却找不到任何输入框：把题目容器的结构打出来，一眼能看出填空框是什么做的
try {
const now = Date.now();
if (now - quizBlankDiagAt > 10000) {
quizBlankDiagAt = now;
const html = String((suspect || node.parentElement).outerHTML || '').replace(/\s+/g, ' ').slice(0, 500);
console.warn(`%c填空/简答识别：找到【${kind}】题，但题目里没有可填写的输入框/编辑框。题目结构：${html}`, 'color:#FF9800');
}
} catch (_) { /* 忽略 */ }
continue;
}
if (seenCards.has(chosen)) continue;
seenCards.add(chosen);
const title = textQuestionTitle(chosen, kind);
if (!title) continue;
found.push({ kind, title, blanks, card: chosen, doc });
for (const input of blanks) usedInputs.add(input);
}
return found;
}

function untaggedTextQuestions(doc, usedInputs) {
const found = [];
const seenCards = new Set();
for (const input of fillableElements(doc.body)) {
if (usedInputs.has(input)) continue;
const card = textQuestionCardFor(input);
if (!card || seenCards.has(card) || !textQuestionCardLooksReal(card)) continue;
seenCards.add(card);
const blanks = fillableElements(card);
const longForm = blanks.some((el) => el.tagName === 'TEXTAREA' ||
el.getAttribute('contenteditable') === 'true' || el.isContentEditable);
const kind = longForm ? '简答题' : '填空题';
const title = textQuestionTitle(card, kind);
if (!title) continue;
found.push({ kind, title, blanks, card, doc });
for (const blank of blanks) usedInputs.add(blank);
}
return found;
}

function extractTextQuestions(onlyDocs) {
const questions = [];
for (const doc of (Array.isArray(onlyDocs) ? onlyDocs : courseDocuments())) {
if (!doc.body || !isQuizTextDocument(doc)) continue;
const usedInputs = new Set();
try { questions.push(...taggedTextQuestions(doc, usedInputs)); } catch (_) { /* 忽略 */ }
try { questions.push(...untaggedTextQuestions(doc, usedInputs)); } catch (_) { /* 忽略 */ }
}
return questions;
}

// 成绩页上的填空/简答题：输入框已经没了，只剩下“我的答案 / 正确答案”两行。
// 只用来读答案、记纠错，不能拿来作答（没有输入框就填不进去）。
function reviewTextQuestions() {
const found = [];
for (const doc of courseDocuments()) {
if (!doc.body) continue;
const seen = new Set();
let walker;
try { walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT); } catch (_) { continue; }
let node;
while ((node = walker.nextNode())) {
const match = clean(node.textContent).match(textKindPattern);
if (!match || !visible(node.parentElement)) continue;
let card = node.parentElement;
let chosen = null;
for (let depth = 0; card && depth < 9; depth++, card = card.parentElement) {
let cardText = '';
try { cardText = clean(card.innerText); } catch (_) { cardText = ''; }
if (distinctKindTags(cardText, textKindPattern).size > 1) break;
if (optionElements(card).length >= 2) break;
if (fillableElements(card).length) break;
if (!/我的答案|你的答案|正确答案/.test(cardText)) continue;
chosen = card;
break;
}
if (!chosen || seen.has(chosen)) continue;
seen.add(chosen);
const title = textQuestionTitle(chosen, match[1]);
if (!title) continue;
let blanks = 1;
try {
// “我的答案”和“正确答案”里都会出现“第一空：”，按不同空号去重，别把空数算成两倍
const labels = new Set(clean(chosen.innerText).match(/第\s*[0-9一二三四五六七八九十]+\s*空/g) || []);
if (labels.size > blanks) blanks = Math.min(labels.size, 10);
} catch (_) { /* 忽略 */ }
found.push({ kind: match[1], title, blanks: new Array(blanks).fill(null), card: chosen, doc, review: true });
}
}
return found;
}

// 选择题数组上挂一份 textQuestions，交卷/计数/重做都按“选择题 + 填空简答”合计
function attachTextQuestions(questions, onlyDocs) {
const list = Array.isArray(questions) ? questions : [];
let textQuestions = [];
try { textQuestions = extractTextQuestions(onlyDocs); } catch (_) { textQuestions = []; }
// 指定了框架范围时，抽出来的填空/简答本来就在这个范围里，不用再按第一题所在框架过滤
if (list.length && !Array.isArray(onlyDocs)) textQuestions = textQuestions.filter((question) => question.doc === list[0].doc);
if (textQuestions.length) list.textQuestions = textQuestions;
else delete list.textQuestions;
return list;
}

function paperQuestions(questions) {
const list = Array.isArray(questions) ? questions.slice() : [];
if (questions && Array.isArray(questions.textQuestions)) list.push(...questions.textQuestions);
return list;
}

function paperQuestionTotal(questions) {
return (Array.isArray(questions) ? questions.length : 0) +
(questions && Array.isArray(questions.textQuestions) ? questions.textQuestions.length : 0);
}

function paperDoc(questions) {
const list = paperQuestions(questions);
return list.length ? list[0].doc : null;
}

// loose：平台按钮文字可能带空格、换行或多个图标子节点，去掉空白再比更稳
function findButton(doc, label, loose) {
const compact = (value) => (loose ? clean(value).replace(/\s+/g, '') : clean(value));
const target = loose ? compact(label) : label;
const candidates = Array.from(doc.querySelectorAll('button,a,input[type="button"],input[type="submit"],[role="button"],div,span'))
.filter((el) => visible(el) && compact(el.value || el.innerText) === target);
return candidates.find((el) => /^(BUTTON|A|INPUT)$/.test(el.tagName)) ||
candidates.find((el) => !Array.from(el.children).some((child) => compact(child.innerText) === target)) || null;
}

// 不同课程/作业页的提交按钮叫法不一样，统一找一遍
const QUIZ_SUBMIT_LABELS = ['提交', '交卷', '提交答案', '提交试卷', '交卷并查看结果'];
function findQuizSubmit(doc) {
for (const label of QUIZ_SUBMIT_LABELS) {
// 平台的按钮文字常被拆成“提 交”或塞了图标节点：精确匹配之后再用去空白匹配兜一次
const button = findButton(doc, label) || findButton(doc, label, true);
if (button) return button;
}
// 文字里带空格/图标读不出来时，按按钮类名兜底（卷面底部基本都是 btnSubmit/submitBtn）
let candidates = [];
try { candidates = Array.from(doc.querySelectorAll('a,button,input[type="button"],input[type="submit"],[role="button"],div,span')); } catch (_) { return null; }
const matched = candidates.filter((el) => {
if (!visible(el) || el.disabled) return false;
const hint = `${el.className || ''} ${el.id || ''}`.toLowerCase();
const text = clean(el.value || el.innerText).replace(/\s+/g, '');
return /submit|tijiao/.test(hint) || /^(提交|交卷|提交答案|提交试卷|交卷并查看结果)$/.test(text);
});
return matched.find((el) => /^(A|BUTTON|INPUT)$/.test(el.tagName)) || matched[0] || null;
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

// 这一节的测验已经确认没有重做入口时，弹窗里的“下一节/继续观看”才是正确选择：
// 再点“去学习”只会回到同一张成绩页，然后下一节又被弹回来，无限循环。
function findLeaveChapterDialogProceed(dialog) {
const labels = ['下一节', '继续观看', '继续学习下一节', '跳过此节'];
for (const label of labels) {
const button = findButtonIn(dialog, label);
if (button) return { button, label, proceed: true };
}
let nodes = [];
try { nodes = Array.from(dialog.querySelectorAll('button,a,input,[role="button"],.layui-layer-btn0,.layui-layer-btn1')); } catch (_) { return null; }
for (const el of nodes) {
if (!visible(el)) continue;
const text = clean(el.value || el.innerText || '').replace(/\s+/g, '');
if (!text || text.length > 12) continue;
if (/^(下一节|继续观看|跳过此节|跳过)$/.test(text)) return { button: el, label: text, proceed: true };
}
return null;
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
// 这一节已经确认过测验没有重做入口：优先点“下一节/继续观看”真的离开，
// 否则“去学习→成绩页→下一节→又被弹回来”会无限循环
const skipSection = typeof quizNoRedoKnown === 'function' && quizNoRedoKnown();
let found = skipSection ? findLeaveChapterDialogProceed(dialog) : null;
if (!found) found = findLeaveChapterDialogButton(dialog);
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
if (found.proceed) {
console.warn(`%c这一节的测验已确认没有重做入口，点击弹窗里的“${found.label}”继续往下学`, 'color:#FF9800');
found.button.scrollIntoView({ block: 'center' });
found.button.click();
return { label: found.label, proceed: true };
}
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

// 试卷的滚动容器：题目有时不是一次性全部渲染，往下滚一点才会加载出来。
// 只认真正能滚的大容器，避免把页面里各种小弹层都滚一遍。
function quizScrollCandidates(doc) {
const list = [];
if (!doc || !doc.body) return list;
const roots = [doc.scrollingElement, ...Array.from(doc.querySelectorAll('div,section,main,article,form'))];
for (const el of roots) {
if (!el || list.includes(el)) continue;
try {
if (el.scrollHeight <= el.clientHeight + 100) continue;
const style = doc.defaultView.getComputedStyle(el);
if (!/(auto|scroll)/.test(style.overflowY)) continue;
list.push(el);
} catch (_) { /* 忽略 */ }
if (list.length >= 4) break;
}
return list;
}

async function nudgeQuizScroll(doc) {
for (const scroller of quizScrollCandidates(doc)) {
try {
const bottom = scroller.scrollHeight - scroller.clientHeight;
if (bottom <= 0) continue;
scroller.scrollTop = Math.min(bottom, scroller.scrollTop + Math.max(400, scroller.clientHeight * 0.8));
} catch (_) { /* 忽略 */ }
}
await sleep(200);
}

// 诊断用：题量对不上时，把卷面分节（一、单选题（共2题）…）、题型标签、填空/简答输入框
// 数量列出来。这样下次再卡住，控制台日志就能直接看出缺的是哪一类题。
function quizPaperSnapshot(doc) {
const info = { headings: [], tags: {}, textInputs: 0, pager: false };
// 传进来的是框架文档（页面里就是这么用的），测试里也可能直接传题目容器
const body = doc && (doc.body || (doc.nodeType === 1 ? doc : null));
if (!body) return info;
let text = '';
try { text = String(body.innerText || body.textContent || ''); } catch (_) { return info; }
const headingPattern = /[一二三四五六七八九十]+、\s*([^\s（(]{1,12})\s*(?:[（(]\s*共\s*(\d+)\s*题\s*[）)])?/g;
let match;
while ((match = headingPattern.exec(text)) && info.headings.length < 12) {
info.headings.push({ label: clean(match[1]), count: match[2] ? Number(match[2]) : 0 });
}
for (const tag of text.match(/[\[【]([^\]】]{1,8})[\]】]/g) || []) {
const name = clean(tag.replace(/[\[【\]】]/g, ''));
if (!name) continue;
info.tags[name] = (info.tags[name] || 0) + 1;
}
info.pager = /下一题|下一页|下页|上一题|上一页/.test(text);
// 目录/页头搜索框也是 input[type=text]，以前诊断日志里那个凭空的
// “填空/简答输入框 1 个”就是它，误导排查；统计时把搜索框排除掉
try {
info.textInputs = Array.from(body.querySelectorAll('input[type="text"],input[type="search"],textarea,[contenteditable="true"]'))
.filter((el) => {
const type = String(el.type || '').toLowerCase();
if (type === 'search') return false;
const hint = `${el.placeholder || ''} ${el.id || ''} ${el.className || ''}`;
return !/搜索|查找|search|keyword/i.test(hint);
}).length;
} catch (_) { info.textInputs = 0; }
return info;
}

function describeQuizPaper(info) {
const parts = [];
if (info.headings.length) {
parts.push(`分节：${info.headings.map((item) => `${item.label}${item.count ? `×${item.count}` : ''}`).join('、')}`);
}
if (info.textInputs) parts.push(`填空/简答输入框 ${info.textInputs} 个`);
if (info.pager) parts.push('卷面有分页按钮');
return parts.join('；');
}

// 卷面分节标题（“一、单选题（共2题）”）给出的题量之和。没有“题量：N”时用它来对账，
// 防止只识别出一部分题目就交卷（以前出现过整卷 5 题只答了 1 题就交上去的情况）
function quizHeadingTotal(docOrBody) {
const info = quizPaperSnapshot(docOrBody);
if (!info.headings.length) return null;
const total = info.headings.reduce((sum, item) => sum + (Number(item.count) || 0), 0);
return total > 0 ? total : null;
}

const QUIZ_START_LABELS = ['开始答题', '开始测验', '开始考试', '进入答题', '继续答题', '继续作答'];

async function waitForQuizQuestions() {
let submitDoc = null;
let startClicked = false;
let emptySince = 0;
// 页面上是已完成的视频任务点、测验框架里却没有试卷痕迹：连续这么多毫秒都如此就按“没法作答”处理
let videoInsteadSince = 0;
for (let attempt = 0; attempt < 240; attempt++) {
if (stopped) throw new Error('脚本已停止');
if (quizCompleted()) return null;
submitDoc = quizSubmitDoc();
if (submitDoc) break;
// 图文/阅读任务点被误判成测验时，不要干等 120 秒：8 秒后确认到正文就交回阅读流程
if (attempt >= 16 && attempt % 16 === 0) {
let docCount = 0;
try { docCount = contentFrameDocs().length; } catch (_) { docCount = 0; }
if (docCount) throw new Error('当前页面是阅读/图文任务点，不是章节测验');
}
// 这一节是空的（“暂无内容”，没有题目、没有图文、没有视频）：不会再出现“提交”按钮，
// 稳定 10 秒就交回调用处去点“下一节”。留 10 秒是为了不误伤“题目只是加载慢”的测验。
if (quizSectionLooksEmpty()) {
if (!emptySince) emptySince = Date.now();
else if (Date.now() - emptySince >= 10000) {
const emptyError = new Error('这一节是空的（页面显示“暂无内容”），没有题目可答');
emptyError.emptyQuizSection = true;
throw emptyError;
}
} else {
emptySince = 0;
}
// 页面上真正显示的是“已经完成的视频任务点”，而测验这边既没有题目、也没有任何试卷痕迹：
// 说明这个“章节测验”只是平台预加载的空壳框架（或这一节的测验本来就没有内容），
// 再等也不会出现题目。稳定 15 秒仍如此，就按“没法自动作答”处理，交回调用处点“下一节”。
if (!stepProbe().quizPage && completedVideoTaskPointShown()) {
if (!videoInsteadSince) videoInsteadSince = Date.now();
else if (Date.now() - videoInsteadSince >= 15000) {
const videoInsteadError = new Error('这一节显示的是已完成的视频任务点，测验框架里没有题目');
videoInsteadError.emptyQuizSection = true;
throw videoInsteadError;
}
} else {
videoInsteadSince = 0;
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
// 只按“提交按钮所在框架”找题：平台切页时会把上一份成绩页留在别的隐藏框架里，
// 混着数题会一直和卷面题量对不上；按钮在外层、题目在别的框架时退回全页面识别
// 统一走 quizPaperCandidates：题型标签缺失/重复时会按选项结构自动补题，
// 补回来的题和正常识别的题一样交给 DeepSeek 作答
let questions = quizPaperCandidates(submitDoc) || [];
if (!paperQuestionTotal(questions)) questions = attachTextQuestions(extractQuestions());
const textQuestions = questions.textQuestions || [];
const total = questions.length + textQuestions.length;
const countText = clean(submitDoc.body.innerText).match(/题量\s*[:：]\s*(\d+)/);
const expected = countText ? Number(countText[1]) : quizHeadingTotal(submitDoc);
if (total && (!expected || total === expected)) {
const textSignature = textQuestions.map((q) => `${q.kind}:${q.title}:${q.blanks.length}`).join('|');
const signature = questions.map((q) => `${q.kind}:${q.title}:${q.options.length}`).join('|') +
(textSignature ? `|${textSignature}` : '');
stableCount = signature === previousSignature ? stableCount + 1 : 0;
previousSignature = signature;
if (stableCount >= 3) return questions;
} else {
stableCount = 0;
previousSignature = '';
}
// 题目可能分段渲染：等待期间持续往下滚一点，别只滚动一次就干等
if (attempt > 0 && attempt % 10 === 0) await nudgeQuizScroll(submitDoc);
if (attempt > 0 && attempt % 30 === 0) {
const info = quizPaperSnapshot(submitDoc);
const extra = describeQuizPaper(info);
const expectedText = expected ? `，卷面写着题量 ${expected} 道` : '';
const split = textQuestions.length ? `（选择 ${questions.length} 道，填空/简答 ${textQuestions.length} 道）` : '';
console.log(`测验题目仍在加载，已等待 ${attempt / 2} 秒；当前识别 ${total} 道${split}${expectedText}${extra ? `；${extra}` : ''}`);
}
await sleep(500);
}
const timeoutInfo = describeQuizPaper(quizPaperSnapshot(submitDoc));
throw new Error(`测验框架已打开，但等待 120 秒仍未识别完整题目${timeoutInfo ? `（${timeoutInfo}）` : ''}。可运行 app.inspectQuiz() 查看当前识别结果`);
}

async function askDeepSeek(questions) {
const payload = questions.map((q, i) => ({
id: i + 1,
type: q.kind,
question: q.title,
options: q.options.map((o) => ({ letter: o.letter, text: o.text })),
}));
// 只打印字符串，不把对象交给控制台：长时间开着的页面会被 DevTools 留着不放，越积越多
console.log(`本次发送给 DeepSeek 的题干和选项：${JSON.stringify(payload)}`);
return requestDeepSeekAnswers(payload);
}

// 填空题/简答题：没有选项，把“有几个空”告诉 AI，让它按空返回文字答案
async function askDeepSeekText(textQuestions) {
const payload = textQuestions.map((q, i) => ({
id: i + 1,
type: q.kind,
question: q.title,
blanks: Math.max(1, q.blanks.length),
}));
console.log(`本次发送给 DeepSeek 的填空题/简答题：${JSON.stringify(payload)}`);
return requestDeepSeekAnswers(payload);
}

async function requestDeepSeekAnswers(payload) {
if (DIRECT_MODE) return PAGE.__deepseekAsk(payload);
// DeepSeek 上游忙的时候会回 “HTTP 503 Service is too busy”，本地服务再把它包成 502 转发给页面。
// 以前只重试 429/503，一遇到 502 就当作致命错误，整节测验停在原地。现在所有 5xx、429 和网络抖动
// 都按指数退避一直重试（最多约两小时），只要服务恢复就接着作答；配置错误（Key 无效、没设置 Key）
// 这类重试也没用的错误仍然立刻停下，避免白等。
let wait = 5000;
for (let attempt = 1; ; attempt++) {
if (typeof stopped !== 'undefined' && stopped) throw new Error('脚本已停止');
let response;
try {
response = await fetch(`${LOCAL_URL}/answer`, {
method: 'POST',
headers: { 'Content-Type': 'application/json', 'X-Xuexitong-Token': LOCAL_TOKEN },
body: JSON.stringify({ questions: payload }),
signal: AbortSignal.timeout(900000),
});
} catch (error) {
if (attempt >= 240) throw new Error(`连续 ${attempt} 次无法连接本地 DeepSeek 服务。请确认启动窗口仍在运行。详情：${error.message}`);
console.warn(`%c连接本地 DeepSeek 服务失败（${error.message}），${Math.round(wait / 1000)} 秒后重试（第 ${attempt} 次）`, 'color:#FF9800');
await sleep(wait);
wait = Math.min(Math.round(wait * 1.5), 30000);
continue;
}
const data = await response.json().catch(() => null);
if (response.ok) return data.answers;
const message = data?.error || `本地 DeepSeek 服务返回 HTTP ${response.status}`;
// 上游 4xx 被本地服务包成 502 后，真正原因在 message 里：这类错误重试不会变好
const permanent = /\bHTTP (400|401|402|403|404|409|413|415|422)\b/.test(message) ||
/尚未设置|API Key|invalid api key|authentication|余额不足|insufficient/i.test(message);
const retryable = !permanent && (response.status === 408 || response.status === 425 || response.status === 429 || response.status >= 500);
if (retryable && attempt < 240) {
console.warn(`%cDeepSeek 服务暂时不可用（${message}），${Math.round(wait / 1000)} 秒后重试（第 ${attempt} 次）`, 'color:#FF9800');
await sleep(wait);
wait = Math.min(Math.round(wait * 1.5), 30000);
continue;
}
throw new Error(message);
}
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

function validateTextAnswers(textQuestions, answers) {
if (!Array.isArray(answers) || answers.length !== textQuestions.length) throw new Error('AI 返回的填空/简答题数量不匹配');
const result = new Map();
for (const item of answers) {
if (!Number.isInteger(item.id) || result.has(item.id) || !Array.isArray(item.texts))
throw new Error('AI 返回的填空/简答答案格式错误');
const q = textQuestions[item.id - 1];
if (!q) throw new Error('AI 返回未知题号');
const texts = item.texts.map((value) => clean(value));
if (texts.length !== q.blanks.length)
throw new Error(`第 ${item.id} 道${q.kind}有 ${q.blanks.length} 个空，AI 返回了 ${texts.length} 个答案，已停止提交`);
if (texts.some((value) => !value)) throw new Error(`第 ${item.id} 道${q.kind} AI 未给出完整答案，已停止提交`);
if (texts.some((value) => value.length > 300)) throw new Error(`第 ${item.id} 道${q.kind} AI 答案过长，已停止提交`);
result.set(item.id, texts);
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
// 平台把重做页的选项置灰（disabled/readonly）时，点击不会有任何反应：先去掉限制再点
try {
for (const input of q.card.querySelectorAll('input[type="radio"],input[type="checkbox"]')) {
if (input.disabled) input.disabled = false;
if (input.readOnly === true) input.readOnly = false;
}
} catch (_) { /* 忽略 */ }
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

// 直接改 value 在很多前端框架里不会触发绑定：用原生 setter + input/change 事件模拟真实输入
function setNativeInputValue(el, value) {
const doc = el.ownerDocument;
const win = doc && doc.defaultView;
const proto = el.tagName === 'TEXTAREA'
? (win && win.HTMLTextAreaElement && win.HTMLTextAreaElement.prototype)
: (win && win.HTMLInputElement && win.HTMLInputElement.prototype);
const descriptor = proto && Object.getOwnPropertyDescriptor(proto, 'value');
if (descriptor && typeof descriptor.set === 'function') descriptor.set.call(el, value);
else el.value = value;
}

function dispatchTextEvent(el, type) {
try {
const doc = el.ownerDocument;
const win = doc && doc.defaultView;
const event = new (win && win.Event ? win.Event : Event)(type, { bubbles: true });
el.dispatchEvent(event);
} catch (_) { /* 忽略 */ }
}

function blankValueOf(el) {
if (el && el.tagName === 'IFRAME') return editorFrameValue(el);
if (el.getAttribute && el.getAttribute('contenteditable') === 'true' || el.isContentEditable) {
try { return clean(el.textContent); } catch (_) { return ''; }
}
return clean(el.value);
}

async function writeTextBlank(el, value) {
if (stopped) throw new Error('脚本已停止');
try { el.scrollIntoView({ block: 'center' }); } catch (_) { /* 忽略 */ }
if (el && el.tagName === 'IFRAME') {
writeEditorFrame(el, value);
await sleep(200);
return;
}
// 有些平台重做时填空框是 disabled/readonly，去掉属性才能写进去
try { if (el.disabled) el.disabled = false; } catch (_) { /* 忽略 */ }
try { if (el.readOnly === true) el.readOnly = false; } catch (_) { /* 忽略 */ }
try { el.focus(); } catch (_) { /* 忽略 */ }
if (el.getAttribute && (el.getAttribute('contenteditable') === 'true' || el.isContentEditable)) {
el.textContent = value;
} else {
setNativeInputValue(el, value);
}
dispatchTextEvent(el, 'input');
dispatchTextEvent(el, 'change');
dispatchTextEvent(el, 'keyup');
try { el.blur(); } catch (_) { /* 忽略 */ }
await sleep(120);
}

// 按空顺序把答案填进卷面；填完复查一遍，框架重建导致没填上的再补一次
async function fillTextAnswers(textQuestions, answers) {
if (!Array.isArray(textQuestions) || !textQuestions.length) return;
const wanted = [];
textQuestions.forEach((question, index) => {
const values = answers.get(index + 1) || [];
const blanks = fillableElements(question.card);
if (blanks.length !== question.blanks.length) {
throw new Error(`第 ${index + 1} 道${question.kind}的输入框数量变了（${question.blanks.length} → ${blanks.length}），已停止提交`);
}
question.blanks = blanks;
wanted.push({ question, values });
});
for (const item of wanted) {
for (let i = 0; i < item.question.blanks.length; i++) {
await writeTextBlank(item.question.blanks[i], item.values[i] || '');
}
}
await sleep(250);
// 复查：某个空被平台清掉时重填一次；仍然清掉说明页面不接受输入，停止提交
const missing = [];
for (const item of wanted) {
for (let i = 0; i < item.question.blanks.length; i++) {
const value = item.values[i] || '';
if (blankValueOf(item.question.blanks[i]) !== value) missing.push({ el: item.question.blanks[i], value });
}
}
if (!missing.length) return;
console.warn(`%c有 ${missing.length} 个填空没写进去，正在重填`, 'color:#FF9800');
for (const item of missing) {
await writeTextBlank(item.el, item.value);
}
await sleep(250);
const stillMissing = missing.filter((item) => blankValueOf(item.el) !== item.value);
if (stillMissing.length) throw new Error(`有 ${stillMissing.length} 个填空没写进去（页面可能不接受自动输入），已停止提交`);
}

async function confirmSubmitDialog() {
let clicked = 0;
for (let i = 0; i < 40; i++) {
if (stopped) throw new Error('脚本已停止');
const request = findSubmitConfirmRequest();
if (request) {
const message = clean(request.text);
if (/未作答|请选择|请作答|答完/.test(message) && !/确认提交|确定提交|提交试卷|确认交卷/.test(message))
throw new Error(`平台拒绝提交：${message}`);
let label = message;
try {
const content = request.container.querySelector('#popcontent');
if (content && visible(content)) label = clean(content.innerText) || label;
} catch (_) { /* 忽略 */ }
console.log(`确认平台提交窗口：${label || '提交'}`);
fireClick(request.button);
clicked++;
await sleep(800);
continue;
}
if (clicked) return;
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
// 确认框又弹出来了（点“提交”后平台再问一次）：接着点，别当成已经交卷
if (findSubmitConfirmRequest()) {
await confirmSubmitDialog();
elapsedHalfSeconds = 0;
continue;
}
if (quizCompleted()) return;
// 平台弹出“未达到及格线，请重做”：交卷已经生效，结果交给 waitForQuizResult 判断，别再干等成绩页
if (quizFailureDialog()) return;
// 提交后页面往往会直接切换，按钮消失说明已经交上去了，不用无限等成绩
if (elapsedHalfSeconds >= 20 && !findQuizSubmit(submitDoc) && !findSubmitConfirmRequest()) {
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
const dialogLabel = typeof dialogAction === 'object' ? dialogAction.label : dialogAction;
if (typeof dialogAction === 'object' && dialogAction.proceed) {
// 确认没有重做入口后点了“下一节/继续观看”：不取消切换，继续等新小节加载
console.log(`%c已点击弹窗里的“${dialogLabel}”，继续切换下一节`);
clickedAt = Date.now();
nextLogAt = clickedAt + 15000;
continue;
}
app._nextUnitPending = false;
app._doneVideos = previousDoneVideos;
console.log(`%c平台提示本章还有任务点未完成，已点击“${dialogLabel}”，取消切换下一节，回到本页继续完成`);
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
if (typeof app._noteProgress === 'function') app._noteProgress();
invalidateDocumentScan();
app._safeStopped = false;
app._nextUnitPending = false;
// 新小节：视频加载等待重新开始计
app._videoLoadWaitSince = 0;
app._videoWaitGaveUpSection = '';
app._stallRestarts = 0;
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
// 和真正作答时用同一套识别（含按选项结构的兜底补题），排查时看到的就是脚本实际会答的题
const submitDoc = quizSubmitDoc();
const questions = (submitDoc && quizPaperCandidates(submitDoc)) || attachTextQuestions(extractQuestions());
return [
...questions.map((q, i) => ({
id: i + 1, type: q.kind, question: q.title,
options: q.options.map((o) => `${o.letter}. ${o.text}`),
})),
...(questions.textQuestions || []).map((q, i) => ({
id: questions.length + i + 1, type: q.kind, question: q.title, blanks: q.blanks.length,
})),
];
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

// —— 卡住时的 AI 页面恢复 ——
// 有些页面脚本认不出下一步该点哪里（例如成绩页只剩一条“未达到及格线，请重做”，
// 平台的“重做”入口被藏了起来），于是整段脚本就停在原地。这里把当前页面能看到的文字
// 和可点元素整理成一份快照发给 DeepSeek，让它在有限的动作里选一个，脚本照着做。
// DeepSeek 的对话接口只收文字、不收图片：所谓“识别屏幕内容”，就是把屏幕上显示的内容读成文字。
const AI_RESCUE_COOLDOWN = 45000;
const AI_RESCUE_MAX = 12;
// 这些按钮一旦点错就是不可挽回的操作（交卷、删数据、退出），AI 不准碰
const AI_RESCUE_BLOCKED = /交卷|提交试卷|删除|清空|退出登录|注销|退课|取消报名/;
let aiRescueBusy = false;
let aiRescueAt = 0;
let aiRescueCount = 0;
let aiRescueKey = '';
let aiRescueLimitWarned = false;
// 正在为“成绩未达标”的测验找重做入口：这段时间 AI 只能点测验相关元素，
// 不能再点视频/目录/章节名，否则会离开成绩页、把视频倒回开头
let aiRescueQuizMode = false;

function aiRescuePageKey() {
try {
const label = activeCatalogLabel() || app._currentStepTitle() || '';
return `${String(location.pathname || '')}${String(location.search || '')}|${label}`;
} catch (_) {
return '';
}
}

// 把页面上看得见的内容整理成文字快照：整页文字给 AI 看上下文，短文字控件给 AI 选。
// 先放真正可点的按钮，再放任务点/标签，最后才放普通 div/span（“未达到及格线，请重做”这类徽标）。
function buildPageSnapshot(reason) {
const elements = [];
const textParts = [];
const docs = courseDocuments();
// 成绩未达标的页面只把测验相关元素交给 AI。以前 AI 会点“视频/目录/章节名”，
// 把页面带回视频开头重看，看起来像脚本在倒退
let quizMode = aiRescueQuizMode;
if (!quizMode) {
try { quizMode = quizFailureShown(); } catch (_) { quizMode = false; }
}
for (const doc of docs) {
try {
const text = clean(doc.body?.innerText || '');
if (text) textParts.push(text);
} catch (_) { /* 跨域框架读不到就算了 */ }
}
const groups = [
{ selector: 'button,a,input,[role="button"],[onclick]', max: 60 },
{ selector: 'label,li,td,th', max: 40 },
{ selector: 'div,span,p', max: 24, innermost: true },
];
for (const group of groups) {
for (const doc of docs) {
if (elements.length >= 40) break;
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll(group.selector)); } catch (_) { continue; }
for (const el of nodes) {
if (elements.length >= 40) break;
if (!visible(el)) continue;
let label = '';
try { label = clean(el.getAttribute('aria-label') || el.value || el.innerText || el.getAttribute('placeholder') || ''); } catch (_) { label = ''; }
if (!label || label.length > group.max) continue;
if (AI_RESCUE_BLOCKED.test(label)) continue;
// 成绩状态文字（“未达到及格线，请重做”）不是可点入口，别让 AI 去点
if (quizStatusText.test(label)) continue;
if (quizMode) {
// 视频/播放/目录/章节名都会离开成绩页（点章节名还可能把视频倒回开头）
if (/视频|播放|音频|观看|目录|章节列表/.test(label)) continue;
// 只保留能让测验继续的入口
// 注意不含“下一节”：成绩页上让 AI 点下一节，只会撞上“还有任务点未完成”被带回来
if (!/重做|重新|再做|重测|重考|开始答题|开始测验|答题|测验|继续|去学习|去完成|确定|确认|关闭|取消|查看|详情|下一题|返回|学习测验|章节测验/.test(label)) continue;
}
// 只要最里层的元素：外层容器带同样的文字，点它会点偏
let hasInner = false;
try { hasInner = Boolean(el.querySelector('button,a,input,[role="button"],[onclick]')); } catch (_) { hasInner = false; }
if (hasInner) continue;
if (group.innermost) {
// 纯容器（div>span 同一行字）只保留真正显示文字的那一层，点击事件还能正常冒泡上去
let innerSame = false;
try {
innerSame = Array.from(el.children || []).some((child) => clean(child.innerText || '').replace(/\s+/g, '') === label.replace(/\s+/g, ''));
} catch (_) { innerSame = false; }
if (innerSame) continue;
}
const tag = String(el.tagName || '').toLowerCase();
if (!tag) continue;
if (elements.some((item) => item.text === label)) continue;
elements.push({ id: elements.length + 1, tag, text: label, cls: String(el.className || '').slice(0, 60), el });
}
}
}
const payload = {
reason: String(reason || '').slice(0, 300),
url: String(location.href || '').slice(0, 2000),
title: clean(document.title || '').slice(0, 200),
chapter: clean(activeCatalogLabel() || '').slice(0, 200),
text: clean(textParts.join(' ')).slice(0, 2500),
controls: elements.map(({ id, tag, text, cls }) => ({ id, tag, text, cls })),
};
return { payload, elements };
}

async function requestPageAction(snapshot) {
if (DIRECT_MODE) {
if (typeof PAGE.__deepseekAct === 'function') return PAGE.__deepseekAct(snapshot);
return null;
}
let wait = 5000;
for (let attempt = 1; ; attempt++) {
if (stopped) throw new Error('脚本已停止');
let response;
try {
response = await fetch(`${LOCAL_URL}/act`, {
method: 'POST',
headers: { 'Content-Type': 'application/json', 'X-Xuexitong-Token': LOCAL_TOKEN },
body: JSON.stringify({ snapshot }),
signal: AbortSignal.timeout(120000),
});
} catch (error) {
if (attempt >= 3) throw new Error(`连接本地 DeepSeek 服务失败：${error.message}`);
console.warn(`连接本地 DeepSeek 服务失败（${error.message}），${Math.round(wait / 1000)} 秒后重试`);
await sleep(wait);
wait = Math.min(Math.round(wait * 1.5), 20000);
continue;
}
const data = await response.json().catch(() => null);
if (response.ok) return data && data.action ? data.action : null;
const message = (data && data.error) || `本地服务返回 HTTP ${response.status}`;
const retryable = response.status === 408 || response.status === 425 || response.status === 429 || response.status >= 500;
if (retryable && attempt < 3) {
console.warn(`AI 页面恢复请求暂时失败（${message}），${Math.round(wait / 1000)} 秒后重试`);
await sleep(wait);
wait = Math.min(Math.round(wait * 1.5), 20000);
continue;
}
throw new Error(message);
}
}

// 执行 AI 选的动作。返回 true 表示确实做了点什么，false 表示“等待”或没做成。
async function runPageAction(action, built) {
if (!action || typeof action !== 'object') return false;
const name = String(action.action || '');
const reason = clean(action.reason || '') || '无理由';
console.log(`%cAI 选择的操作：${name}${action.id ? ` #${action.id}` : ''}（${reason}）`, 'color:#2196F3');
if (name === 'click') {
const target = built.elements[Number(action.id) - 1];
if (!target || !target.el || !target.el.isConnected) {
console.warn(`%cAI 选中的第 ${action.id} 个元素已经不在页面上了，这次不点`, 'color:#FF9800');
return false;
}
let quizMode = aiRescueQuizMode;
if (!quizMode) {
try { quizMode = quizFailureShown(); } catch (_) { quizMode = false; }
}
// 兜底：就算 AI 还是选了视频/播放入口，也不能点——点了会离开成绩页
if (quizMode && /视频|播放|音频|观看|目录/.test(target.text || '')) {
console.warn(`%cAI 想点“${target.text}”，这是视频/目录入口；成绩未达标的页面不能离开测验，这次不点`, 'color:#FF9800');
return false;
}
fireClick(target.el);
console.log(`%c已点击“${target.text}”，等页面响应`, 'color:#4CAF50');
await sleep(1500);
app._noteProgress();
return true;
}
if (name === 'scroll') {
for (const doc of courseDocuments()) {
try { doc.defaultView?.scrollTo?.(0, doc.documentElement.scrollHeight); } catch (_) { /* 忽略 */ }
}
await sleep(1200);
app._noteProgress();
return true;
}
if (name === 'next' || name === 'skip') {
let quizMode = aiRescueQuizMode;
if (!quizMode) {
try { quizMode = quizFailureShown(); } catch (_) { quizMode = false; }
}
// 成绩未达标时不能再跳节：平台会弹“任务点未完成”把页面带回来，
// 就是用户看到的那种循环。找入口的事交给 runQuizRedo 的固定流程
if (quizMode) {
console.warn('%c成绩未达标的页面上不能让 AI 跳节，先继续找重做入口', 'color:#FF9800');
return false;
}
}
if (name === 'next') {
app._noteProgress();
if (typeof app.nextUnit === 'function') app.nextUnit();
return true;
}
if (name === 'skip') {
app._noteProgress();
// AI 明确判断这一节做不了：允许它再跳一次（否则会被“刚跳过一次”的冷却挡住）
lastSkippedQuiz = { label: '', at: 0 };
await skipQuizSection('AI 判断这一节无法继续');
return true;
}
// wait：什么也不做，把页面交回停滞自检
return false;
}

// 页面长时间没进展时调用一次：识别页面 → 问 AI → 执行。同一页最多试 AI_RESCUE_MAX 次，
// 两次之间至少隔 AI_RESCUE_COOLDOWN，避免把请求和点击刷爆。
async function aiPageRescue(reason) {
if (stopped || aiRescueBusy || app._destroyed || app._refreshing) return false;
const now = Date.now();
const key = aiRescuePageKey();
if (key !== aiRescueKey) {
aiRescueKey = key;
aiRescueCount = 0;
aiRescueLimitWarned = false;
}
if (aiRescueCount >= AI_RESCUE_MAX) {
if (!aiRescueLimitWarned) {
aiRescueLimitWarned = true;
console.warn(`%c这一页已经让 AI 尝试过 ${AI_RESCUE_MAX} 次，不再重复识别，交给停滞自检处理`, 'color:#F44336');
}
return false;
}
if (aiRescueAt && now - aiRescueAt < AI_RESCUE_COOLDOWN) return false;
aiRescueAt = now;
aiRescueCount += 1;
aiRescueBusy = true;
app._aiRescueRunning = true;
console.log(`%c页面长时间没有进展（${reason}），把屏幕上显示的内容发给 DeepSeek，让它决定下一步`, 'color:#2196F3');
try {
const built = buildPageSnapshot(reason);
if (!built.elements.length && !built.payload.text) {
console.warn('%c当前页面既没有文字也没有可点元素，AI 无法判断，交给停滞自检处理', 'color:#FF9800');
return false;
}
const action = await requestPageAction(built.payload);
if (!action) {
console.warn('%cDeepSeek 没有给出可执行的动作，交给停滞自检处理', 'color:#FF9800');
return false;
}
return await runPageAction(action, built);
} catch (error) {
console.warn(`%cAI 页面恢复没有成功（${error && error.message ? error.message : error}），交给停滞自检处理`, 'color:#FF9800');
return false;
} finally {
aiRescueBusy = false;
app._aiRescueRunning = false;
}
}
app._aiPageRescue = aiPageRescue;

// 这一节没法自动作答（内容是空的 / 题目一直加载不出来）时，跳过它继续往下学。
// 用户要的是全自动，所以不停下来等人：点“下一节”就走。
// 两种情况下不再硬跳：同一节刚跳过又被平台带回来（说明这里确实有未完成任务点），
// 或者已经连着跳了 10 节，避免在空小节之间无限打转。
async function skipQuizSection(reason) {
const label = activeCatalogLabel() || app._currentStepTitle() || '';
const recent = lastSkippedQuiz.label && lastSkippedQuiz.label === label && Date.now() - lastSkippedQuiz.at < 180000;
// 同一节被平台带回来第 3 次：平台既不给重做入口、又不让离开，再跳也只会在这一节打转
if (label) {
const bounces = (quizBounceCounts.get(label) || 0) + 1;
quizBounceCounts.set(label, bounces);
if (bounces >= 3) {
quizStuckLabel = label;
console.error(`%c这一节（${label}）已经连续 ${bounces} 次被“当前章节还有任务点未完成”带回来，平台又没有重做入口；再点“下一节”只会继续打转，脚本停止在这一节反复尝试。请手动处理这一节的测验（或联系老师开放重做），处理完再点一次书签继续`, 'color:#F44336');
quizBusy = false;
return;
}
}
if (recent) {
// 不能因为“刚跳过一次”就把脚本锁死：以前这里直接 return，页面就永远停在成绩页上。
// 现在先让 AI 看一眼页面能不能打开重做入口；AI 也没办法时，停滞自检再过一会儿会接着处理。
quizBusy = false;
const labelText = label || '当前小节';
console.warn(`%c这一节（${labelText}）刚跳过一次又被带回来了，说明平台认为这里还有未完成任务点；让 AI 看看页面上有没有能继续的操作`, 'color:#FF9800');
aiPageRescue(`这一节刚跳过一次又被带回来：${reason}`).then((acted) => {
if (stopped || app._destroyed) return;
if (!acted) {
console.warn('%cAI 也没找到能让这一节继续的操作；如果确认这一节不用做，可执行 app.nextUnit() 手动继续', 'color:#FF9800');
return;
}
quizBusy = false;
setTimeout(() => {
if (stopped || app._destroyed || app._nextUnitPending) return;
if (typeof app.play === 'function') app.play();
else app._advanceChapterTest();
}, 1500);
}).catch(() => { /* aiPageRescue 自己会打日志 */ });
return;
}
if (emptyQuizSkips >= 10) {
console.error('连续跳过 10 个没能自动作答的小节，仍未找到可学习内容，已停止，请手动检查章节');
return;
}
emptyQuizSkips++;
lastSkippedQuiz = { label, at: Date.now() };
console.warn(`%c这一节没法自动作答（${reason}），自动点击“下一节”跳过（第 ${emptyQuizSkips} 次）`, 'color:#FF9800');
quizBusy = false;
try {
await goToNextStep();
} catch (error) {
app._nextUnitPending = false;
console.error('跳过没法作答的小节时出错:', error);
}
}

// —— 章节测验“必须满分”的补答流程 ——
// 有些测验要求 100 分，交卷后显示“未达到及格线，请重做”。
// 这时不能点“下一节”（会被“还有任务点未完成”弹窗拉回来），也不该原样重交：
// 先读结果页每题的对错，答对的照抄、答错的换一个（页面给了正确答案就直接用），点“重做”再交，
// 直到通过或次数用完。AI 会答错，所以每答错一次就排除一个答案，靠排除法也能全对。
const quizAnswerMemory = new Map();
// 填空题/简答题的答案：AI 给过的原样保存（重做时不用再问一遍），
// 结果页给出“正确答案”时直接换成正确答案
const quizTextMemory = new Map();

// 错题记忆只放在内存里的话，脚本“整页刷新重新找重做入口”后就全没了，
// 刷新回来又会把原来那些错答案再交一遍。存进 sessionStorage，刷新后接着用。
const QUIZ_MEMORY_STORAGE = 'xxtQuizMemory:v1';
function pruneQuizLists(list) {
return (Array.isArray(list) ? list : []).filter((item) => Array.isArray(item) && item.length).slice(-24);
}
function saveQuizMemory() {
try {
const answers = {};
let answerCount = 0;
for (const [key, mem] of quizAnswerMemory) {
if (!mem || typeof mem !== 'object') continue;
const trimmed = { tried: pruneQuizLists(mem.tried), wrong: pruneQuizLists(mem.wrong) };
if (Array.isArray(mem.correct) && mem.correct.length) trimmed.correct = [...mem.correct];
if (Array.isArray(mem.lastAnswer) && mem.lastAnswer.length) trimmed.lastAnswer = [...mem.lastAnswer];
if (!trimmed.tried.length && !trimmed.wrong.length && !trimmed.correct && !trimmed.lastAnswer) continue;
// 只保留最近 200 道题，防止一学期下来把 sessionStorage 撑爆
if (answerCount >= 200) break;
answers[key] = trimmed;
answerCount++;
}
const texts = {};
let textCount = 0;
for (const [key, mem] of quizTextMemory) {
if (!mem || typeof mem !== 'object') continue;
const trimmed = {};
if (Array.isArray(mem.correct) && mem.correct.length) trimmed.correct = [...mem.correct];
if (Array.isArray(mem.last) && mem.last.length) trimmed.last = [...mem.last];
if (Array.isArray(mem.wrong) && mem.wrong.length) trimmed.wrong = pruneQuizLists(mem.wrong);
if (!trimmed.correct && !trimmed.last && !trimmed.wrong) continue;
if (textCount >= 100) break;
texts[key] = trimmed;
textCount++;
}
window.sessionStorage.setItem(QUIZ_MEMORY_STORAGE, JSON.stringify({ answers, texts, at: Date.now() }));
} catch (_) { /* 存不了就算了，不影响流程 */ }
}
function loadQuizMemory() {
try {
const raw = window.sessionStorage.getItem(QUIZ_MEMORY_STORAGE);
if (!raw) return;
const data = JSON.parse(raw);
if (!data || typeof data !== 'object') return;
// 超过一天的记忆不要了：课程改题、题库换题后旧答案只会帮倒忙
if (Number(data.at) && Date.now() - Number(data.at) > 24 * 60 * 60 * 1000) {
window.sessionStorage.removeItem(QUIZ_MEMORY_STORAGE);
return;
}
for (const key of Object.keys(data.answers || {})) {
const mem = data.answers[key];
if (!key || !mem || typeof mem !== 'object') continue;
quizAnswerMemory.set(key, {
tried: pruneQuizLists(mem.tried),
wrong: pruneQuizLists(mem.wrong),
correct: Array.isArray(mem.correct) && mem.correct.length ? [...mem.correct] : null,
lastAnswer: Array.isArray(mem.lastAnswer) && mem.lastAnswer.length ? [...mem.lastAnswer] : undefined,
});
}
for (const key of Object.keys(data.texts || {})) {
const mem = data.texts[key];
if (!key || !mem || typeof mem !== 'object') continue;
const loaded = {};
if (Array.isArray(mem.correct) && mem.correct.length) loaded.correct = [...mem.correct];
if (Array.isArray(mem.last) && mem.last.length) loaded.last = [...mem.last];
if (Array.isArray(mem.wrong) && mem.wrong.length) loaded.wrong = pruneQuizLists(mem.wrong);
quizTextMemory.set(key, loaded);
}
} catch (_) { /* 读不了就当没有记忆 */ }
}
loadQuizMemory();
let quizRedoActive = false;
// 平台确实不给重做入口的小节：记下来，短时间内不再等入口、整页刷新、点成绩文字，
// 避免在成绩页上来回打转（成绩页本身没有“重做”按钮时，再找一万次也不会出现）
const quizNoRedoUntil = new Map();
const QUIZ_NO_REDO_TTL = 20 * 60 * 1000;

// 重做循环会在同一张试卷上反复提交。平台的每次交卷都会重建一大块页面，
// 十几轮下来渲染进程内存能涨到几个 G，最后标签页直接 “Out of Memory”。
// 这里在每次交卷前先量一下：JS 堆或 DOM 节点数已经异常就先停下，
// 宁可停在这一轮，也不能让整个标签页崩掉。
function quizMemoryHot() {
let heap = 0;
let limit = 0;
let nodes = 0;
try {
const mem = performance.memory;
if (mem) {
heap = Number(mem.usedJSHeapSize) || 0;
limit = Number(mem.jsHeapSizeLimit) || 0;
}
} catch (_) {
heap = 0;
limit = 0;
}
// 题目在 iframe 里，节点数要把所有框架一起算，才能看出平台每轮重建后有没有越堆越多
try {
for (const doc of courseDocuments()) {
try { nodes += doc.getElementsByTagName('*').length; } catch (_) { /* 忽略 */ }
}
} catch (_) {
try { nodes = document.getElementsByTagName('*').length; } catch (_) { nodes = 0; }
}
// JS 堆到 1 GB（或接近 V8 上限）已经远高于正常课程页，再交卷就离崩溃只差几步
const hot = heap > 1024 * 1024 * 1024 || (limit > 0 && heap > limit * 0.7) || nodes > 120000;
if (hot) {
console.warn(`%c页面占用已经很高（JS 堆 ${Math.round(heap / 1048576)} MB，节点 ${nodes} 个），先停止重做，避免标签页崩溃`, 'color:#F44336');
}
return hot;
}

function quizNoRedoKey() {
try { return activeSectionKey() || activeCatalogLabel() || ''; } catch (_) { return ''; }
}

function markQuizNoRedo() {
const key = quizNoRedoKey();
if (key) quizNoRedoUntil.set(key, Date.now());
}

function quizNoRedoKnown() {
const key = quizNoRedoKey();
if (!key) return false;
const at = quizNoRedoUntil.get(key) || 0;
return Boolean(at) && Date.now() - at < QUIZ_NO_REDO_TTL;
}

// 同一节最多整页刷新一次去重新找“重做”入口；刷新后还是没有就跳过，
// 防止“刷新→没有→再刷新”来回死循环。时间记在 sessionStorage 里，整页刷新后仍然有效。
function quizReloadBudget(label, now) {
const key = `xxtQuizReloadAt:${String(label || '')}`;
let at = 0;
try { at = Number(window.sessionStorage.getItem(key)) || 0; } catch (_) { at = 0; }
if (at && now - at < 15 * 60 * 1000) return false;
try { window.sessionStorage.setItem(key, String(now)); } catch (_) { /* 忽略 */ }
return true;
}

const QUIZ_REDO_PATTERN = /^(点击)?(重做(此题|本题|试卷|试题)?|再做一次|再做一遍|重测|重考|再测一次|再考一次|重新测试|重新测验|重新考试|重新作答|重新答题|重新做题|再答一次|再次答题|再次作答)$/;
const QUIZ_FAILURE_PATTERN = /未达到及格线|未达到合格线|不及格|请重做|未通过|未达标/;

// 题目身份用“题型+题干”。结果页会把“我的答案/正确答案/回答正确”混进题干里，
// 这些内容要先去掉，否则交卷前和结果页上的同一道题会被当成两道，记忆就对不上了
function quizQuestionKey(question) {
const title = clean(question.title)
.replace(/得分\s*[：:][\s\S]*$/, '')
.replace(/我的答案\s*[：:][\s\S]*$/, '')
.replace(/正确答案\s*[：:][\s\S]*$/, '')
.replace(/回答(?:正确|错误)[\s\S]*$/, '')
.trim()
.slice(0, 120);
return `${question.kind}:${title}`;
}

// quizCompleted 每半秒就会被问一次，读整页文字很贵：一秒内复用同一个结果
let quizFailureCache = { at: 0, value: false };
function quizFailureShown() {
const now = Date.now();
if (quizFailureCache.at && now - quizFailureCache.at < 1000) return quizFailureCache.value;
let value = false;
try {
value = courseDocuments().some((doc) => {
let text = '';
try { text = String(doc.body?.innerText || ''); } catch (_) { return false; }
return QUIZ_FAILURE_PATTERN.test(text);
});
} catch (_) {
value = false;
}
quizFailureCache = { at: now, value };
return value;
}

function findQuizRedoButton() {
for (const doc of courseDocuments()) {
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('button,a,input,label,li,td,th,div,span,p,i,b,strong,em,[role="button"],[onclick]')); } catch (_) { continue; }
for (const el of nodes) {
if (!visible(el)) continue;
let text = '';
try {
// 有的重做入口是纯图标，只有 title/aria-label 写着“重做”
text = clean(el.value || el.innerText || el.getAttribute('aria-label') || el.getAttribute('title') || '').replace(/\s+/g, '');
} catch (_) { text = ''; }
if (!text || text.length > 16) continue;
// “重做（剩余 2 次）”这类带次数说明的写法：去掉括号内容再判断
const label = text.replace(/[（(][^）)]*[）)]/g, '');
let hit = QUIZ_REDO_PATTERN.test(label);
if (!hit) {
// 文案被平台改成别的写法时，再看 id/class/onclick 里有没有 redo 之类的线索
let hint = '';
try { hint = `${el.id || ''} ${el.className || ''} ${el.getAttribute('onclick') || ''}`.toLowerCase(); } catch (_) { hint = ''; }
hit = /redo|chongzuo|again|retest|retry/.test(hint) && /重做|重测|重考|重新|再[做测答考]/.test(label);
}
// “请点此重做”“重做本题”这类更长的文案：只对真正可点的控件放宽匹配。
// “未达到及格线，请重做”是平台的状态文字（不是按钮），绝不能当成重做入口去点。
if (!hit) {
let interactive = false;
try {
interactive = /^(BUTTON|A|INPUT)$/.test(el.tagName) ||
el.getAttribute('role') === 'button' ||
el.hasAttribute('onclick');
} catch (_) { interactive = false; }
if (interactive && label.length <= 20 && /重做|重测|重考|重新作答|重新答题/.test(label)) hit = true;
}
if (!hit) continue;
if (el.querySelector('button,a')) continue;
return el;
}
}
return null;
}

// 平台把“重做”做成一条带字的小卡片/徽标（“未达到及格线，请重做”）时，按按钮文字匹配不到。
// 这里找“文字很短、含重做字样、里面没有再套控件”的最里层元素：它可能是真入口，
// 也可能只是状态文字。点完由调用方确认页面有没有变化，不会仅凭它下结论。
function findLooseRedoControl() {
for (const doc of courseDocuments()) {
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('button,a,input,[role="button"],[onclick],label,li,td,th,span,div,p,i,b,strong,em')); } catch (_) { continue; }
for (const el of nodes) {
if (!visible(el)) continue;
let text = '';
try {
text = clean(el.innerText || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '').replace(/\s+/g, '');
} catch (_) { text = ''; }
if (!text || text.length > 24) continue;
if (!/重做|重测|重考|重新作答|重新答题/.test(text)) continue;
// “未达到及格线，请重做”是成绩状态文字，不是按钮：点它不会有任何反应
if (quizStatusText.test(text)) continue;
// 弹窗里的文字不是重做入口；真正的入口在弹窗后面
let inDialog = false;
try { inDialog = Boolean(el.closest('#popcontent,.layui-layer,.layui-layer-dialog,.el-dialog,.el-message-box,[role="dialog"],[role="alertdialog"]')); } catch (_) { inDialog = false; }
if (inDialog) continue;
let hasInner = false;
try { hasInner = Boolean(el.querySelector('button,a,input,[role="button"],[onclick]')); } catch (_) { hasInner = false; }
if (hasInner) continue;
// 外层容器和里面的文字子元素会同时命中：取真正显示文字的那一层，点击事件照样冒泡
let innerSame = false;
try {
innerSame = Array.from(el.children || []).some((child) => clean(child.innerText || '').replace(/\s+/g, '') === text);
} catch (_) { innerSame = false; }
if (innerSame) continue;
return el;
}
}
return null;
}

// 找不到重做入口时，把页面上能点的按钮都打出来，下一次一看日志就知道平台改成了什么文案
function quizEntryCandidates() {
const rows = [];
for (const doc of courseDocuments()) {
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('button,a,input,[role="button"],[onclick]')); } catch (_) { continue; }
for (const el of nodes) {
if (!visible(el)) continue;
let text = '';
try { text = clean(el.value || el.innerText || '').replace(/\s+/g, ''); } catch (_) { text = ''; }
if (!text || text.length > 16) continue;
const name = `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ''}`;
if (!rows.includes(`${name}: ${text}`)) rows.push(`${name}: ${text}`);
if (rows.length >= 30) return rows;
}
}
return rows;
}

// 左栏“任务点”里的“章节测验”一行：平台用事件委托处理点击，没有 onclick 属性、
// 也不是 button/a，普通的按钮扫描根本看不到它。但点它才是重新打开测验任务的入口——
// 成绩页上那条“未达到及格线，请重做”只是状态文字，本身不能点。
function findQuizTaskPoint() {
// 先找“任务点”标题，只在它所在的那一块里找“章节测验”行：
// 测验卡片标题也是“章节测验”，按位置分不干净（目录还可能放在右边），按所属区块分最稳。
for (const doc of courseDocuments()) {
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('div,span,h3,h4,p,dt,li')); } catch (_) { continue; }
const headings = [];
for (const el of nodes) {
if (!visible(el)) continue;
let text = '';
try { text = clean(el.innerText || ''); } catch (_) { continue; }
if (text.replace(/[\s\d（）()]+/g, '') !== '任务点') continue;
headings.push(el);
}
for (const heading of headings) {
let root = heading.parentElement;
for (let depth = 0; depth < 2 && root; depth++) {
const hit = findQuizTaskRowIn(root);
if (hit) return hit;
root = root.parentElement;
}
}
}
return findQuizTaskPointFallback();
}

// 在“任务点”标题所在区块里取最里层的“章节测验”行（去掉未完成数量徽标再比）
function findQuizTaskRowIn(root) {
let nodes = [];
try { nodes = Array.from(root.querySelectorAll('li,dd,dt,div,span,p,a')); } catch (_) { return null; }
for (const el of nodes) {
if (!visible(el)) continue;
let text = '';
try { text = clean(el.innerText || ''); } catch (_) { continue; }
const normalized = text.replace(/[\s\d（）()]+/g, '');
// 任务点行常带状态：“章节测验 未完成”“章节测验（已提交）”。
// 只认“章节测验/测验任务”开头、文字很短的行，避免把整块目录当成任务点
const isQuizRow = normalized === '章节测验' || normalized === '测验任务' ||
((normalized.startsWith('章节测验') || normalized.startsWith('测验任务')) && normalized.length <= 12);
if (!isQuizRow) continue;
let hasInner = false;
try {
hasInner = Array.from(el.children || []).some((child) => clean(child.innerText || '').replace(/[\s\d（）()]+/g, '') === normalized);
} catch (_) { hasInner = false; }
if (hasInner) continue;
return el;
}
return null;
}

// 没有“任务点”标题的版式：只认任务点类名/行列标签，绝不把右侧卡片标题当成任务点
function findQuizTaskPointFallback() {
for (const doc of courseDocuments()) {
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('li,dd,dt,div,span,p,a')); } catch (_) { continue; }
for (const el of nodes) {
if (!visible(el)) continue;
let text = '';
try { text = clean(el.innerText || ''); } catch (_) { continue; }
const normalized = text.replace(/[\s\d（）()]+/g, '');
const isQuizRow = normalized === '章节测验' || normalized === '测验任务' ||
((normalized.startsWith('章节测验') || normalized.startsWith('测验任务')) && normalized.length <= 12);
if (!isQuizRow) continue;
let hint = '';
try { hint = `${el.className || ''} ${el.id || ''}`.toLowerCase(); } catch (_) { hint = ''; }
if (!(/task|point|job|mission|rw/.test(hint) || /^(LI|DD|DT)$/.test(el.tagName))) continue;
let hasInner = false;
try {
hasInner = Array.from(el.children || []).some((child) => clean(child.innerText || '').replace(/[\s\d（）()]+/g, '') === normalized);
} catch (_) { hasInner = false; }
if (hasInner) continue;
return el;
}
}
return null;
}

// 成绩页的按钮/试卷经常比题目晚几秒渲染：等一会儿再下结论，顺手滚到底部把懒加载的按钮带出来
async function waitForQuizRedoEntry(ms) {
// 按轮数等，不用墙钟时间：测试里 sleep 是立即返回的，也不会卡住 15 秒
const rounds = Math.max(1, Math.round(ms / 500));
let scrolled = false;
let startClicked = false;
let tabClicked = false;
let pointClicked = false;
let looseClicked = false;
for (let i = 0; i < rounds && !stopped; i++) {
if (quizFailureDialog()) {
await dismissQuizFailureDialog();
continue;
}
if (findQuizRedoButton()) return 'retry';
if (editableQuizPaper() || quizPaperAnswerable()) return 'paper';
// 先点左栏“任务点”里的“章节测验”重新打开测验任务：成绩页本身没有可点的重做入口，
// 平台要在任务点上重新进入才会给出“开始答题/重做”
if (!pointClicked) {
const point = findQuizTaskPoint();
if (point) {
pointClicked = true;
console.log('%c点击左侧“任务点”里的“章节测验”，重新打开测验任务', 'color:#2196F3');
fireClick(point);
await sleep(800);
continue;
}
}
if (!startClicked && typeof findTextControl === 'function' && typeof QUIZ_START_LABELS !== 'undefined') {
const start = courseDocuments().map((doc) => findTextControl(doc.documentElement, QUIZ_START_LABELS)).find(Boolean);
if (start) {
startClicked = true;
console.log('%c检测到测验入口，点击“开始答题”', 'color:#2196F3');
fireClick(start);
await sleep(800);
continue;
}
}
// 重新进入小节后平台可能先显示视频，切回“学习测验”页签才能看到测验卡片
if (!tabClicked && !startClicked && typeof findTextControl === 'function') {
const tab = courseDocuments().map((doc) => findTextControl(doc.documentElement, ['学习测验', '章节测验'])).find(Boolean);
if (tab) {
tabClicked = true;
console.log('%c点击“学习测验”页签，切换到测验卡片', 'color:#2196F3');
fireClick(tab);
// 测验卡片渲染比页签慢，等久一点再判断，别刚切过去就说没有重做入口
await sleep(1600);
for (const doc of courseDocuments()) {
try { await nudgeQuizScroll(doc); } catch (_) { /* 忽略 */ }
}
continue;
}
}
// 常规入口都点过一遍还是没有：试着点带“重做”字样的卡片/徽标（可能是平台换的新入口）
if (!looseClicked) {
const loose = findLooseRedoControl();
if (loose) {
looseClicked = true;
console.log('%c找到带“重做”字样的元素，点击它看能不能打开重做入口', 'color:#2196F3');
fireClick(loose);
await sleep(1200);
// 平台可能先弹“确定要重做吗”，确定后才会出现试卷
if (typeof confirmQuizRedoDialog === 'function') await confirmQuizRedoDialog();
continue;
}
}
if (!scrolled) {
scrolled = true;
// 有的成绩页要把题目滚到底部才会渲染出“重做/提交”按钮
for (const doc of courseDocuments()) {
try { doc.defaultView?.scrollTo?.(0, doc.documentElement.scrollHeight); } catch (_) { /* 忽略 */ }
}
try {
const last = extractQuestions().slice(-1)[0];
if (last && last.card) last.card.scrollIntoView({ block: 'end' });
} catch (_) { /* 忽略 */ }
}
// 有些页面的滚动容器不是整页，而是播放器里的一个 div：每轮都往底部推一下，
// 成绩页最下面的“重做”按钮才会被渲染出来
for (const doc of courseDocuments()) {
try { await nudgeQuizScroll(doc); } catch (_) { /* 忽略 */ }
}
await sleep(500);
}
return null;
}

// 平台说“未达到及格线，请重做”时弹的是只有“取消/确定”的提示框，页面上并没有“重做”按钮。
// 不点掉这个框，脚本就只能干等着——成绩页和“重做”按钮都在它后面。
// 这个框可能是平台自己的 #popcontent/#popok 弹窗（提交确认用的也是它），也可能是 layui/el-dialog
function quizFailureDialog() {
for (const doc of courseDocuments()) {
// 1) 平台自定义弹窗：#popcontent 显示文字，#popok 是“确定”
let content = null;
try { content = doc.getElementById('popcontent'); } catch (_) { content = null; }
if (content && visible(content)) {
let text = '';
try { text = clean(content.innerText); } catch (_) { text = ''; }
if (text && QUIZ_FAILURE_PATTERN.test(text)) {
let confirm = null;
try {
const popok = doc.getElementById('popok');
if (popok && visible(popok)) confirm = popok;
} catch (_) { confirm = null; }
let element = content;
try {
element = content.closest('#popup,.popup,.popup_con,.layui-layer,.el-dialog,[role="dialog"],[role="alertdialog"]') ||
content.parentElement || content;
} catch (_) { element = content; }
return { element, confirm, text };
}
}
// 2) 框架式弹窗
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('.layui-layer,.layui-layer-dialog,.layui-layer-page,.el-message-box,.el-dialog,[role="dialog"],[role="alertdialog"],.modal')); } catch (_) { continue; }
for (const el of nodes) {
if (!visible(el)) continue;
if (el.querySelector('.layui-layer,.el-message-box,[role="dialog"]')) continue;
let text = '';
try { text = clean(el.innerText); } catch (_) { continue; }
if (!text || !QUIZ_FAILURE_PATTERN.test(text)) continue;
return { element: el, confirm: null, text };
}
}
return null;
}

// 点“确定”关掉提示框；没有按钮就点右上角的关闭叉
async function dismissQuizFailureDialog() {
const dialog = quizFailureDialog();
if (!dialog) return false;
const element = dialog.element || dialog;
let target = dialog.confirm ||
findButtonIn(element, '确定') || findButtonIn(element, '确认') || findButtonIn(element, '知道了') || findButtonIn(element, '重做');
if (!target) {
try { target = element.querySelector('.layui-layer-close,.el-message-box__close,.close'); } catch (_) { target = null; }
}
if (!target) {
console.warn('%c“未达到及格线”提示框上没找到可点的按钮，请手动关掉它', 'color:#F44336');
return false;
}
console.log('%c关闭“未达到及格线，请重做”提示框', 'color:#FF9800');
fireClick(target);
// 提示框的文字还在页面上，缓存会一直判成“未达标”，这里直接清掉重新读
quizFailureCache = { at: 0, value: false };
await sleep(1200);
return true;
}

// “确认提交？”弹窗：正按钮可能写着“提交”，也可能写着“确定”。
// 必须读“按钮所在这个弹窗”的文字——页面别处可能残留着上一次“未达到及格线”的 #popcontent，
// 读错了就会把提交确认当成失败提示，点完框还在原地
function findSubmitConfirmRequest() {
for (const doc of courseDocuments()) {
let nodes = [];
try {
nodes = Array.from(doc.querySelectorAll('#popup,.popup,[id*="popup"],[id*="Popup"],[class*="popup"],[class*="Popup"],[class*="dialog"],[id*="dialog"],.layui-layer,.el-dialog,[role="dialog"],[role="alertdialog"],.modal'));
} catch (_) { continue; }
for (const container of nodes) {
if (!visible(container)) continue;
if (container.querySelector('#popup,.popup,.layui-layer,.el-dialog,[role="dialog"]')) continue;
let text = '';
try { text = clean(container.innerText); } catch (_) { continue; }
if (!text || text.length > 300) continue;
if (QUIZ_FAILURE_PATTERN.test(text)) continue; // 不及格提示交给重做流程
if (!/确认提交|确定提交|提交试卷|确认交卷|是否提交|请确认提交/.test(text)) continue;
let button = null;
try { button = container.querySelector('#popok'); } catch (_) { button = null; }
if (!button || !visible(button)) {
button = ['提交', '确定', '确认'].map((label) => findButtonIn(container, label)).find(Boolean) || null;
}
if (!button) continue;
return { container, button, text };
}
// 兜底：弹窗类名不认识时，从“提交/确定/确认”按钮往上找文字很短、且写着确认提交的祖先
let buttons = [];
try { buttons = Array.from(doc.querySelectorAll('button,a,input[type="button"],[role="button"]')); } catch (_) { continue; }
for (const button of buttons) {
if (!visible(button)) continue;
const label = clean(button.value || button.innerText || '').replace(/\s+/g, '');
if (!/^(提交|确定|确认|提交试卷|确认提交)$/.test(label)) continue;
let scope = button.parentElement;
for (let depth = 0; scope && depth < 6; depth++, scope = scope.parentElement) {
if (!visible(scope)) { scope = null; break; }
let text = '';
try { text = clean(scope.innerText); } catch (_) { continue; }
if (text.length > 200) break;
if (QUIZ_FAILURE_PATTERN.test(text)) { scope = null; break; }
if (!/确认提交|确定提交|提交试卷|确认交卷|是否提交|请确认提交/.test(text)) continue;
return { container: scope, button, text };
}
}
}
return null;
}

// 页面上每题已经带着对错标记：这是上一次的成绩页，不是新测验
function quizPageGraded(questions) {
const list = Array.isArray(questions) ? questions : extractQuestions();
return list.length > 0 && list.some((question) => {
const outcome = quizCardOutcome(question.card);
return outcome.wrong || outcome.right;
});
}

// 判断框架本身是不是用户正看着的那一屏：平台切页时会把上一份成绩页留在隐藏框架里，
// 不区分的话“旧成绩页的提交按钮 + 新试卷的题目”会混在一起，题量永远对不上
function frameVisible(doc) {
if (!doc || doc === document) return true;
try {
const frame = doc.defaultView && doc.defaultView.frameElement;
if (!frame) return true;
return visible(frame);
} catch (_) { return false; }
}

// 提交按钮所在框架：优先取可见的那个（隐藏框架里往往是上一份已经交掉的成绩页）
function quizSubmitDoc() {
let docs = [];
try { docs = courseDocuments(); } catch (_) { return null; }
const withSubmit = docs.filter((doc) => findQuizSubmit(doc));
if (!withSubmit.length) return null;
return withSubmit.find(frameVisible) || withSubmit[0];
}

// 某个框架及其里层框架
function docsWithin(doc) {
const docs = [];
const visit = (item, depth) => {
if (!item || depth > 3 || docs.includes(item)) return;
docs.push(item);
let frames = [];
try { frames = Array.from(item.querySelectorAll('iframe')); } catch (_) { return; }
for (const frame of frames) {
try { visit(frame.contentDocument, depth + 1); } catch (_) { /* 跨域 */ }
}
};
visit(doc, 0);
return docs;
}

// 同一道题在页面上出现两份（旧成绩页副本还在同一个框架里）时按题型+题干+选项去重，
// 否则交卷时会把同一道题算两遍、题量和卷面对不上
function dedupePaperQuestions(questions) {
const seen = new Set();
const unique = [];
for (const question of (Array.isArray(questions) ? questions : [])) {
const options = (question.options || []).map((option) => clean(option.text)).join('/');
const key = `${question.kind}:${clean(question.title).slice(0, 120)}:${options}`;
if (seen.has(key)) continue;
seen.add(key);
unique.push(question);
}
const texts = (questions && Array.isArray(questions.textQuestions)) ? questions.textQuestions : [];
if (texts.length) {
const seenText = new Set();
const uniqueText = texts.filter((question) => {
const key = `${question.kind}:${clean(question.title).slice(0, 120)}:${question.blanks.length}`;
if (seenText.has(key)) return false;
seenText.add(key);
return true;
});
if (uniqueText.length) unique.textQuestions = uniqueText;
}
return unique;
}

function expectedQuizTotal(doc) {
if (!doc || !doc.body) return null;
let text = '';
try { text = clean(doc.body.innerText); } catch (_) { return null; }
const countText = text.match(/题量\s*[:：]\s*(\d+)/);
return countText ? Number(countText[1]) : quizHeadingTotal(doc.body);
}

let quizStructuralLogKey = '';
// 只按“提交按钮所在框架”来识别试卷；提交按钮在外层、题目在别的框架时退回全页面识别
function quizPaperCandidates(submitDoc) {
if (!submitDoc) return null;
const scoped = docsWithin(submitDoc);
let questions = attachTextQuestions(extractQuestions(scoped), scoped);
if (!paperQuestionTotal(questions)) questions = attachTextQuestions(extractQuestions());
const total = paperQuestionTotal(questions);
const expected = expectedQuizTotal(submitDoc);
// 正常识别题量不够时，按选项结构补题（题型标签没渲染、重复渲染或换了写法都能补回来）。
// 只补到卷面题量为止：补多了反而会因为“识别数 > 题量”永远判定不完整
if (total < (expected || 1)) {
const knownCards = questions.map((question) => question.card).filter(Boolean);
const extra = structuralQuizQuestions(scoped).filter((question) =>
!knownCards.some((card) => card === question.card ||
(card.contains && card.contains(question.card)) ||
(question.card.contains && question.card.contains(card))));
const room = expected ? Math.max(0, expected - total) : extra.length;
if (extra.length && room > 0) {
const texts = questions.textQuestions || [];
const added = extra.slice(0, room);
questions = questions.slice().concat(added);
if (texts.length) questions.textQuestions = texts;
// 这就是“题目识别不了就交给 AI”的兜底：题型标签缺失/重复时先按选项结构把题补全，
// 再把补全后的完整题干和选项发给 DeepSeek 识别题型并作答（DeepSeek 接口只收文字，收不了图片）
const key = `${total}:${expected || 0}:${added.length}`;
if (key !== quizStructuralLogKey) {
quizStructuralLogKey = key;
console.log(`%c卷面题型标签不完整，已按选项结构自动补全 ${added.length} 道题（识别到 ${total} 道，补后 ${questions.length} 道），再交给 DeepSeek 作答`, 'color:#4CAF50');
}
}
}
return dedupePaperQuestions(questions || []);
}

function quizPaperExpected(questions) {
const paperBody = paperDoc(questions)?.body || null;
if (!paperBody) return { paperBody: null, expectedTotal: null };
return { paperBody, expectedTotal: expectedQuizTotal(paperBody.ownerDocument) };
}

// 找到了提交按钮、题量却对不上时，把“识别到几题 / 卷面几题 / 分节和输入框情况”打出来，
// 这样下次卡住时控制台就能直接看出是缺了哪一类题，而不是干等一个不会出现的“重做”入口
let quizPaperGapKey = '';
function reportQuizPaperGap(questions, expectedTotal) {
const total = paperQuestionTotal(questions);
const key = `${total}:${expectedTotal || 0}`;
if (key === quizPaperGapKey) return;
quizPaperGapKey = key;
if (!total) {
console.warn('%c卷面识别：找到了“提交”按钮，但页面上暂时没识别到题目，先不交卷', 'color:#FF9800');
return;
}
let detail = '';
try {
const info = typeof quizPaperSnapshot === 'function' ? quizPaperSnapshot(paperDoc(questions)?.body) : null;
if (info && typeof describeQuizPaper === 'function') detail = describeQuizPaper(info);
} catch (_) { detail = ''; }
// 把已识别到的题逐条列出来：题量对不上时能直接看出缺的是哪一类、哪一题
let list = '';
try {
list = paperQuestions(questions).map((question, index) =>
`${index + 1}.${question.kind}:${clean(question.title).slice(0, 16)}${question.options ? `(${question.options.length}选项)` : ''}`
).join('；');
} catch (_) { list = ''; }
console.warn(`%c卷面识别：找到“提交”按钮，识别到 ${total} 题，卷面标注 ${expectedTotal ? `${expectedTotal} 题` : '题量未知'}${detail ? `（${detail}）` : ''}${list ? `。已识别：${list}` : ''}，先不交卷，等页面渲染完再核对`, 'color:#FF9800');
}

// 点掉提示框后，平台要么跳到成绩页（带对错标记和“重做”按钮），要么直接回到可作答的试卷。
// 试卷是异步渲染的：题目数量要稳定两次、并且和“题量：N”对得上，才算真的能作答，
// 否则会只填到半份卷子就交，被平台以“未作答”拒掉
let quizPaperStable = { signature: '', count: 0 };
function editableQuizPaper() {
const submitDoc = quizSubmitDoc();
if (!submitDoc) {
quizPaperStable = { signature: '', count: 0 };
return null;
}
const questions = quizPaperCandidates(submitDoc);
const total = paperQuestionTotal(questions);
if (!total) {
quizPaperStable = { signature: '', count: 0 };
return null;
}
const { expectedTotal } = quizPaperExpected(questions);
if (expectedTotal && expectedTotal !== total) {
quizPaperStable = { signature: '', count: 0 };
reportQuizPaperGap(questions, expectedTotal);
return null;
}
const textSignature = (questions.textQuestions || [])
.map((question) => `${question.kind}:${question.title}:${question.blanks.length}`).join('|');
const signature = questions.map((question) => `${question.kind}:${question.title}:${question.options.length}`).join('|') +
(textSignature ? `|${textSignature}` : '');
if (signature === quizPaperStable.signature) quizPaperStable.count += 1;
else quizPaperStable = { signature, count: 1 };
if (quizPaperStable.count < 2) return null;
return questions;
}

// 不走“连续两屏一致”的稳定计数，直接看页面上有没有一份题量对得上的完整试卷。
// runQuizRedo 开头的“有没有重做入口”判断必须用它：成绩页刚变成可作答试卷时，
// 稳定计数还是 0，用 editableQuizPaper() 会误判成“没有重做入口”，然后开始跳节死循环。
function quizPaperAnswerable() {
const submitDoc = quizSubmitDoc();
if (!submitDoc) return null;
const questions = quizPaperCandidates(submitDoc);
const total = paperQuestionTotal(questions);
if (!total) return null;
const { paperBody, expectedTotal } = quizPaperExpected(questions);
if (!paperBody) return null;
if (expectedTotal && expectedTotal !== total) {
reportQuizPaperGap(questions, expectedTotal);
return null;
}
return questions;
}

// 等试卷稳定两屏再作答：题量对得上且连续两次识别结果一致，避免只渲染了一半就交卷
async function waitForAnswerableQuizPaper(ms) {
const deadline = Date.now() + Math.max(1000, ms);
let previous = '';
let stable = 0;
while (!stopped && Date.now() < deadline) {
const paper = quizPaperAnswerable();
if (paper) {
const signature = paper.map((question) => `${question.kind}:${question.title}:${(question.options || []).length}`).join('|');
stable = signature === previous ? stable + 1 : 0;
previous = signature;
if (stable >= 1) return paper;
} else {
stable = 0;
previous = '';
}
const doc = quizSubmitDoc();
if (doc) await nudgeQuizScroll(doc);
await sleep(500);
}
return quizPaperAnswerable();
}

async function waitForQuizRedoReady() {
for (let i = 0; i < 30; i++) {
if (stopped) return false;
if (findQuizRedoButton() || quizFailureDialog() || editableQuizPaper()) return true;
await sleep(500);
}
return false;
}

// 判断题的答案在结果页上显示成“我的答案：对 / 错”，不是 A/B 字母。
// 这里把这类文字答案换回选项字母，否则“判错了”读不到，重做时还会把同一个答案再交一遍。
const JUDGE_TRUE_TEXT = /^(对|正确|是|√|✓|✔|true|t)$/i;
const JUDGE_FALSE_TEXT = /^(错|错误|否|×|✗|✘|x|false|f)$/i;
function answerTextLetters(question, value) {
const text = clean(value);
if (!text) return null;
if (/^[A-H](?:\s*[、,，]?\s*[A-H])*$/i.test(text)) {
const letters = Array.from(new Set(text.toUpperCase().match(/[A-H]/g) || []));
return letters.length ? letters : null;
}
const options = (question && Array.isArray(question.options)) ? question.options : [];
const exact = options.find((option) => clean(option.text) === text);
if (exact) return [exact.letter];
if (JUDGE_TRUE_TEXT.test(text)) {
const match = options.find((option) => JUDGE_TRUE_TEXT.test(clean(option.text)));
return [match ? match.letter : 'A'];
}
if (JUDGE_FALSE_TEXT.test(text)) {
const match = options.find((option) => JUDGE_FALSE_TEXT.test(clean(option.text)));
return [match ? match.letter : 'B'];
}
return null;
}

function readMyAnswer(card, question) {
let text = '';
try { text = clean(card.innerText); } catch (_) { return null; }
const match = text.match(/(?:我的答案|你的答案)\s*[：:]\s*([A-H](?:\s*[、,，]?\s*[A-H])*|对|错|正确|错误|是|否|√|✓|×|✗)/);
if (!match) return null;
return answerTextLetters(question, match[1]);
}

// 结果页上这一题判对还是判错、有没有给出正确答案
function quizCardOutcome(card) {
const outcome = { wrong: false, right: false, correct: null, correctText: '' };
if (!card) return outcome;
let text = '';
try { text = clean(card.innerText); } catch (_) { text = ''; }
try {
// 整个题目容器的类名也可能直接标着错（如 "TiMu cuo"）
const cardHint = `${String(card.className || '')} ${String(card.id || '')}`.toLowerCase();
if (/cuo|wrong|incorrect|icon-?cha/.test(cardHint)) outcome.wrong = true;
if (/dui|icon-?gou/.test(cardHint)) outcome.right = true;
// 成绩页的对错图标通常只有一个小图标：有的用 class="cuo"/"dui"，有的用
// icon-cuowu、背景图、SVG，甚至只是给元素上红色/绿色。这里把能读到的线索全拼起来判断，
// 否则“我的答案”读到了、红色的叉没认出来，就会把错题当成未判定，重做时原样再交一遍
for (const el of card.querySelectorAll('i,span,em,b,img,div,p,label,li,td,tr,svg,use,a')) {
let hint = '';
let glyphText = '';
try {
hint = `${String(el.className || '')} ${String(el.id || '')} ` +
`${el.getAttribute('src') || ''} ${el.getAttribute('alt') || ''} ${el.getAttribute('title') || ''} ` +
`${el.getAttribute('aria-label') || ''} ${el.getAttribute('xlink:href') || ''} ${el.getAttribute('href') || ''}`.toLowerCase();
glyphText = clean(el.textContent || '');
const style = el.ownerDocument.defaultView.getComputedStyle(el);
const bg = String(style.backgroundImage || '').toLowerCase();
if (bg && bg !== 'none') hint += ` ${bg}`;
// 纯图标元素（没有文字或只有一个小符号）按颜色兜底：红叉=错，绿勾=对
if (!glyphText || glyphText.length <= 2) {
const rgb = String(style.color || '').match(/rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/);
if (rgb) {
const r = Number(rgb[1]);
const g = Number(rgb[2]);
const b = Number(rgb[3]);
if (r >= 180 && g <= 110 && b <= 110) hint += ' cuo-red';
else if (g >= 120 && r <= 120 && b <= 140) hint += ' dui-green';
}
}
} catch (_) { hint = ''; }
if (/cuo|wrong|incorrect|icon-?cha|answer-?no|叉/.test(hint)) outcome.wrong = true;
if (/dui|icon-?gou|勾/.test(hint)) outcome.right = true;
if (glyphText && glyphText.length <= 3 && /^[✓✔√✗✘×✕]+$/.test(glyphText)) {
if (/[✗✘×✕]/.test(glyphText)) outcome.wrong = true;
else outcome.right = true;
}
}
} catch (_) { /* 忽略 */ }
if (/回答错误|答案错误|答错了|答错啦/.test(text)) outcome.wrong = true;
if (outcome.wrong) outcome.right = false;
else if (/回答正确|答案正确|答对了|答对啦/.test(text)) outcome.right = true;
const match = text.match(/正确答案\s*[：:]\s*([A-H](?:\s*[、,，]?\s*[A-H])*)/);
if (match) {
outcome.correct = Array.from(new Set(match[1].match(/[A-H]/g) || []));
} else {
// 判断/选择题的正确答案也可能写成“正确答案：对 / 错”
const judge = text.match(/正确答案\s*[：:]\s*(对|错|正确|错误|是|否|√|✓|×|✗)/);
if (judge) outcome.correctText = judge[1];
}
return outcome;
}

function pushUniqueAnswer(list, letters) {
const items = Array.isArray(list) ? list : [];
if (!Array.isArray(letters) || !letters.length) return items;
if (!items.some((entry) => Array.isArray(entry) && sameLetters(entry, letters))) items.push([...letters]);
return items;
}

// 填空/简答的答案是一组文字，按“逐空文字完全相同”去重
function pushUniqueText(list, values) {
const items = Array.isArray(list) ? list : [];
if (!Array.isArray(values) || !values.length) return items;
if (!items.some((entry) => Array.isArray(entry) && entry.join('~') === values.join('~'))) items.push([...values]);
return items;
}

// 把结果页上每题的判定记进记忆：答对的照抄、答错的排除、页面给了正确答案就直接用
function recordQuizOutcome() {
let recorded = 0;
let wrongCount = 0;
let rightCount = 0;
const questions = extractQuestions();
questions.forEach((question, index) => {
const key = quizQuestionKey(question);
const outcome = quizCardOutcome(question.card);
const mine = readMyAnswer(question.card, question);
const correct = (outcome.correct && outcome.correct.length ? outcome.correct : null) ||
answerTextLetters(question, outcome.correctText) || null;
const mem = quizAnswerMemory.get(key) || { tried: [], wrong: [], correct: null };
if (correct) {
mem.correct = [...correct];
} else if (outcome.wrong) {
mem.correct = null;
if (mine) mem.wrong = pushUniqueAnswer(mem.wrong, mine);
wrongCount++;
if (mine) {
console.log(`%c成绩页：第 ${index + 1} 题（${question.kind}）判错，我的答案 ${mine.join('')}，重做时换别的选项`, 'color:#FF9800');
} else {
console.warn(`%c成绩页：第 ${index + 1} 题（${question.kind}）判错，但没读到“我的答案”，只能逐项试`, 'color:#FF9800');
}
} else if (outcome.right && mine) {
mem.correct = [...mine];
rightCount++;
}
quizAnswerMemory.set(key, mem);
recorded++;
});
if (wrongCount || rightCount) {
console.log(`%c成绩页识别：答错 ${wrongCount} 题、答对 ${rightCount} 题${correctShownHint(questions) ? '（页面给了正确答案的题会直接按正确答案作答）' : ''}`, 'color:#FF9800');
} else if (questions.length) {
// 对错图标又换样式时，至少把第一题的页面结构打出来，下一次好定位
console.warn('%c成绩页上没读到任何对错标记（平台可能换了图标样式），这轮把所有题都当成“未确认”，重做时逐题换答案', 'color:#FF9800');
try {
const html = String(questions[0].card.outerHTML || '').replace(/\s+/g, ' ').slice(0, 600);
console.warn(`第一题页面结构：${html}`);
} catch (_) { /* 忽略 */ }
}
saveQuizMemory();
return recorded;
}

// 结果页是否给出了“正确答案”：只是用于日志说明
function correctShownHint(questions) {
return questions.some((question) => {
const outcome = quizCardOutcome(question.card);
return Boolean((outcome.correct && outcome.correct.length) || outcome.correctText);
});
}

// 重新作答时怎么选：页面给了正确答案用正确答案，答错过的用排除法换一个，
// 其余的交回 AI；AI 又给出已经判错的答案时同样改成排除法的结果
async function chooseChapterAnswers(questions) {
const answers = new Map();
const pending = [];
for (let i = 0; i < questions.length; i++) {
const question = questions[i];
const mem = quizAnswerMemory.get(quizQuestionKey(question)) || { tried: [], wrong: [], correct: null };
if (mem.correct && mem.correct.length && mem.correct.every((letter) => question.options.some((option) => option.letter === letter))) {
answers.set(i + 1, [...mem.correct]);
continue;
}
if (mem.wrong.length) {
const letters = fallbackLetters(question, { tried: mem.tried, wrong: mem.wrong });
if (letters) {
answers.set(i + 1, letters);
continue;
}
}
// 上一轮选过、但既没判对也没判错的答案：先原样保留，只改动这一轮要试探的那道题
if (Array.isArray(mem.lastAnswer) && mem.lastAnswer.length &&
mem.lastAnswer.every((letter) => question.options.some((option) => option.letter === letter))) {
answers.set(i + 1, [...mem.lastAnswer]);
continue;
}
pending.push({ index: i, question });
}
if (pending.length) {
const got = validateAnswers(pending.map((item) => item.question), await askDeepSeek(pending.map((item) => item.question)));
pending.forEach((item, position) => {
const question = item.question;
const mem = quizAnswerMemory.get(quizQuestionKey(question)) || { tried: [], wrong: [], correct: null };
let letters = got.get(position + 1) || null;
if (letters && mem.wrong.some((entry) => sameLetters(entry, letters))) {
letters = fallbackLetters(question, { tried: mem.tried, wrong: mem.wrong });
}
if (!letters) letters = fallbackLetters(question, { tried: mem.tried, wrong: mem.wrong });
answers.set(item.index + 1, letters);
});
}
return answers;
}

function rememberQuizTried(questions, answers) {
questions.forEach((question, index) => {
const letters = answers.get(index + 1);
if (!Array.isArray(letters) || !letters.length) return;
const key = quizQuestionKey(question);
const mem = quizAnswerMemory.get(key) || { tried: [], wrong: [], correct: null };
mem.tried = pushUniqueAnswer(mem.tried, letters);
mem.lastAnswer = [...letters];
quizAnswerMemory.set(key, mem);
});
saveQuizMemory();
}

// 把“正确答案：甲；乙”这类文字拆成每空的答案；拆不开就当作没读到，不乱改
function splitTextAnswer(text, count) {
const value = clean(text);
if (!value) return [];
// 成绩页上多个空的答案常写成“第一空：甲 第二空：乙”，先把空号本身当作分隔符
const parts = value
.replace(/第\s*[0-9一二三四五六七八九十]+\s*空\s*[：:]?\s*/g, '；')
.split(/\s*[；;|｜]\s*/)
.map((part) => clean(part))
.filter(Boolean);
if (count <= 1) {
const whole = parts.length ? parts.join('；') : '';
return whole ? [whole] : [];
}
return parts.length === count ? parts : [];
}

// 填空题/简答题怎么答：结果页给过正确答案就直接用，否则沿用 AI 上一次给的，再没有才问 AI
async function chooseTextAnswers(textQuestions) {
const answers = new Map();
const pending = [];
textQuestions.forEach((question, index) => {
const mem = quizTextMemory.get(quizQuestionKey(question)) || {};
if (Array.isArray(mem.correct) && mem.correct.length === question.blanks.length) {
answers.set(index + 1, [...mem.correct]);
return;
}
if (Array.isArray(mem.last) && mem.last.length === question.blanks.length) {
answers.set(index + 1, [...mem.last]);
return;
}
pending.push({ index, question });
});
if (pending.length) {
const got = validateTextAnswers(pending.map((item) => item.question), await askDeepSeekText(pending.map((item) => item.question)));
pending.forEach((item, position) => {
const values = got.get(position + 1);
answers.set(item.index + 1, values);
const key = quizQuestionKey(item.question);
const mem = quizTextMemory.get(key) || {};
mem.last = [...values];
quizTextMemory.set(key, mem);
});
saveQuizMemory();
}
return answers;
}

// 结果页上填空题/简答题的“我的答案 / 正确答案”
function recordQuizTextOutcome() {
let recorded = 0;
const cards = new Set();
const list = [];
for (const question of extractTextQuestions()) {
cards.add(question.card);
list.push(question);
}
// 成绩页输入框已经收起来了，也要能读“正确答案”，否则重做时只会把上次的答案再交一遍
for (const question of reviewTextQuestions()) {
if (cards.has(question.card)) continue;
list.push(question);
}
for (const question of list) {
let cardText = '';
try { cardText = clean(question.card.innerText); } catch (_) { continue; }
const correct = cardText.match(/正确答案\s*[：:]\s*([\s\S]*?)(?=\s*(?:我的答案|答案解析|得分|回答正确|回答错误)\s*[：:]?|$)/);
const mine = cardText.match(/我的答案\s*[：:]\s*([\s\S]*?)(?=\s*正确答案\s*[：:]|$)/);
const key = quizQuestionKey(question);
const mem = quizTextMemory.get(key) || {};
let changed = false;
if (correct) {
const values = splitTextAnswer(correct[1], question.blanks.length);
if (values.length) {
mem.correct = values;
changed = true;
recorded++;
}
}
if (mine) {
const values = splitTextAnswer(mine[1], question.blanks.length);
if (values.length) {
mem.last = values;
changed = true;
}
}
// 上次这个空答错了、页面又没给正确答案：别在重做时原样再交一遍，
// 清掉“上次答案”，让重做流程重新问一次
if (!correct && quizCardOutcome(question.card).wrong) {
if (mem.last) delete mem.last;
mem.wrong = pushUniqueText(mem.wrong, mine ? splitTextAnswer(mine[1], question.blanks.length) : []);
changed = true;
}
if (changed) quizTextMemory.set(key, mem);
}
saveQuizMemory();
return recorded;
}

async function clearQuizSelections(questions) {
for (const question of questions) {
try { await clearVideoQuizSelections(question); } catch (_) { /* 忽略 */ }
}
}

async function confirmQuizRedoDialog() {
for (let i = 0; i < 8; i++) {
let button = null;
for (const doc of courseDocuments()) {
let dialogs = [];
try { dialogs = Array.from(doc.querySelectorAll('.layui-layer-dialog,.el-message-box,[role="dialog"],[role="alertdialog"]')).filter((el) => visible(el)); } catch (_) { dialogs = []; }
button = dialogs.map((el) => findButtonIn(el, '确定') || findButtonIn(el, '确认')).find(Boolean) || null;
if (button) break;
}
if (button) {
console.log('%c确认“重做”提示', 'color:#607D8B');
button.click();
await sleep(600);
return true;
}
await sleep(250);
}
return false;
}

// 交卷后等结果页：明确判错、写着不及格，或者每题都判完了，才算有结论
async function waitForQuizResult() {
for (let attempt = 0; attempt < 60; attempt++) {
if (stopped) return { failed: false };
// “确认提交？”还挂着说明这次根本没交上去：先点掉，再继续等结果
if (findSubmitConfirmRequest()) {
await confirmSubmitDialog();
continue;
}
// 提示框一弹出来就说明没通过，不用再等成绩页
if (quizFailureDialog()) return { failed: true };
const retry = findQuizRedoButton();
const failedText = quizFailureShown();
if (failedText && retry) return { failed: true };
if (!failedText && quizCompleted()) return { failed: false };
if (attempt % 3 === 0) {
const outcome = extractQuestions().map((question) => quizCardOutcome(question.card));
const judged = outcome.filter((item) => item.wrong || item.right);
// 有填空题/简答题时，等它们也判完再下结论，别只看选择题就判“全部判完”
const textJudged = extractTextQuestions().every((question) => {
let cardText = '';
try { cardText = clean(question.card.innerText); } catch (_) { return false; }
return /我的答案\s*[：:]|回答正确|回答错误|正确答案\s*[：:]/.test(cardText);
});
if (judged.length && judged.length === outcome.length && textJudged) return { failed: outcome.some((item) => item.wrong) };
}
await sleep(500);
}
return { failed: quizFailureShown() };
}

// 重做循环：关提示框/点重做 → 换答案 → 重新交卷，直到通过或次数用完
async function runQuizRedo(reason) {
if (quizRedoActive) return 'busy';
quizRedoActive = true;
try {
// 这一节刚确认过平台不提供重做入口：别再等入口/刷新/问 AI，直接按“已提交”继续往下学。
// 页面若又出现了新的可作答试卷或“重做”按钮，说明平台改主意了，照常处理
if (quizNoRedoKnown() && !findQuizRedoButton() && !quizPaperAnswerable()) {
console.warn('%c这一节之前确认过平台没有重做入口，不再重复查找，直接继续下一节', 'color:#FF9800');
return 'no-retry';
}
// 上一轮交上去的答案（每题用“|”拼起来）。只要这轮的答案和上一轮一模一样，
// 平台就只会原样再判一次不及格，还会白白重建一遍页面——必须拦住。
let lastAnswerSignature = '';
let paperRounds = 0;
// 整份重做只让 AI 找一次入口：找到就继续，找不到再走刷新/跳过，避免每轮都在同一页上重复问
let quizRedoAiTried = false;
// 重新作答一轮：选答案、交卷、等结果；返回 'passed' / 'failed' / 'memory' / 'exhausted'
const answerAndSubmit = async (questions, attempt) => {
// 交卷前先确认页面还没到崩溃边缘；到了就这一轮都不交，改让整页刷新把内存清掉
if (quizMemoryHot()) {
if (typeof app === 'object' && app && typeof app._autoRefresh === 'function') {
app._autoRefresh('章节测验重做时页面内存占用过高');
}
return 'memory';
}
const answers = await chooseChapterAnswers(questions);
const textQuestions = questions.textQuestions || [];
const textAnswers = textQuestions.length ? await chooseTextAnswers(textQuestions) : new Map();
// 没有“已判对”的题按轮次逐题换答案。不能因为别的题有对错标记就整份原样重交：
// 只要有一道题被标成“对”，以前就会永远停在同一份答案上，12 轮都在重复交同一份卷子
const switchable = [];
questions.forEach((question, index) => {
const mem = quizAnswerMemory.get(quizQuestionKey(question));
const knownRight = mem && Array.isArray(mem.correct) && mem.correct.length > 0;
if (!knownRight) switchable.push(index);
});
if (switchable.length) {
const targetIndex = switchable[(attempt - 1) % switchable.length];
const target = questions[targetIndex];
const mem = quizAnswerMemory.get(quizQuestionKey(target)) || { tried: [], wrong: [], correct: null };
const letters = fallbackLetters(target, { tried: mem.tried, wrong: mem.wrong || [] });
if (letters) {
answers.set(targetIndex + 1, letters);
console.log(`%c这轮换第 ${targetIndex + 1} 题的答案：${letters.join('')}`, 'color:#2196F3');
}
}
const signatureOf = () => questions.map((question, index) => (answers.get(index + 1) || []).join('')).join('|') +
'#' + textQuestions.map((question, index) => (textAnswers.get(index + 1) || []).join('~')).join('|');
// 换完答案还是和上一轮完全一样（选项全试遍/读数把答案锁死了）：再交一遍不会有任何变化
if (signatureOf() === lastAnswerSignature) {
let changed = false;
for (let offset = 0; offset < questions.length && !changed; offset++) {
const index = (attempt + offset) % questions.length;
const target = questions[index];
const mem = quizAnswerMemory.get(quizQuestionKey(target)) || { tried: [], wrong: [], correct: null };
const letters = fallbackLetters(target, { tried: mem.tried, wrong: mem.wrong || [] });
if (!letters || sameLetters(letters, answers.get(index + 1) || [])) continue;
answers.set(index + 1, letters);
changed = true;
console.log(`%c这轮答案和上一轮完全一样，改第 ${index + 1} 题：${letters.join('')}`, 'color:#2196F3');
}
if (!changed) {
console.error('%c所有题目的答案组合都已经交过了，再重交也不会有变化，先停下', 'color:#F44336');
return 'exhausted';
}
}
lastAnswerSignature = signatureOf();
console.table([
...questions.map((question, index) => ({ 题号: index + 1, 题型: question.kind, 选择: (answers.get(index + 1) || []).join(''), 填空: '' })),
...textQuestions.map((question, index) => ({ 题号: questions.length + index + 1, 题型: question.kind, 选择: '', 填空: (textAnswers.get(index + 1) || []).join(' / ') })),
]);
await clearQuizSelections(questions);
await selectAnswers(questions, answers);
await fillTextAnswers(textQuestions, textAnswers);
rememberQuizTried(questions, answers);
await submitQuiz(paperDoc(questions));
const result = await waitForQuizResult();
return result.failed ? 'failed' : 'passed';
};
// 答错一题换一个选项，逐轮把所有选项走一遍（用户要求“又错了就穷举”）。
// 每次交卷前都有内存保护，页面撑不住会先停下刷新，不会把标签页弄崩
for (let attempt = 1; attempt <= 24; attempt++) {
if (stopped) return 'stopped';
// 只有“取消/确定”的提示框先关掉，成绩页/重做按钮才会露出来
if (quizFailureDialog()) {
await dismissQuizFailureDialog();
await waitForQuizRedoReady();
}
recordQuizOutcome();
recordQuizTextOutcome();
const retry = findQuizRedoButton();
if (retry) {
console.warn(`%c${reason}，点击“重做”重新作答（第 ${attempt} 次）`, 'color:#FF9800');
try { retry.scrollIntoView({ block: 'center' }); } catch (_) { /* 忽略 */ }
retry.click();
await sleep(1200);
await confirmQuizRedoDialog();
let questions = null;
try {
questions = await waitForQuizQuestions();
} catch (error) {
console.warn(`%c重做后没等到题目（${error.message}），5 秒后再试`, 'color:#FF9800');
await sleep(5000);
continue;
}
if (!questions) {
// 页面还挂着“重做”或“未达标”，不能当成通过
if (findQuizRedoButton() || quizFailureShown() || quizFailureDialog()) {
console.warn('%c重做后页面仍提示未达标，继续重做', 'color:#FF9800');
await sleep(2000);
continue;
}
console.log('%c重做后页面显示测验已完成', 'color:#4CAF50');
return 'passed';
}
try {
const status = await answerAndSubmit(questions, attempt);
if (status === 'passed') {
console.log('%c重做后已经通过', 'color:#4CAF50');
return 'passed';
}
if (status === 'memory' || status === 'exhausted') return status;
console.log('%c重做后仍未通过，继续换答案', 'color:#FF9800');
} catch (error) {
// 这一轮没做完（AI 服务报错、页面重建）不代表题做不了：换答案的逻辑还在，稍后接着来
console.warn(`%c重做这一轮没做完（${error.message}），5 秒后继续`, 'color:#FF9800');
await sleep(5000);
}
await sleep(2000);
continue;
}
// 没有“重做”按钮：平台点“确定”后可能直接回到可作答的试卷。
// 刚切回来的这一屏稳定计数可能还没攒够，这里多等几秒，别把整份卷子当成“没有重做入口”
const paper = editableQuizPaper() || await waitForAnswerableQuizPaper(8000);
if (paper) {
// 原地重交不会刷新页面，平台的每次重建都留在同一个渲染进程里；
// 这条路最多交 6 次，再多就停下，避免把标签页撑爆
paperRounds++;
if (paperRounds > 10) {
console.error('%c同一张试卷原地重交了 10 次仍未通过，先停下（再交下去只会在同一份答案上打转，还容易把标签页撑崩）', 'color:#F44336');
return 'gave-up';
}
console.log(`%c平台已回到可重新作答的试卷，直接换答案重交（第 ${attempt} 次，这条路第 ${paperRounds}/10 次）`, 'color:#FF9800');
try {
const status = await answerAndSubmit(paper, attempt);
if (status === 'passed') {
console.log('%c重做后已经通过', 'color:#4CAF50');
return 'passed';
}
if (status === 'memory' || status === 'exhausted') return status;
console.log('%c重做后仍未通过，继续换答案', 'color:#FF9800');
} catch (error) {
console.warn(`%c重做这一轮没做完（${error.message}），5 秒后继续`, 'color:#FF9800');
await sleep(5000);
}
await sleep(2000);
continue;
}
// 成绩页刚出来时按钮可能还没渲染，先等一等，不要两秒就判“没救了”
console.warn('%c成绩未达标，先等页面把“重做”入口渲染出来', 'color:#FF9800');
let entry = await waitForQuizRedoEntry(15000);
if (entry) continue;
// 任务点、开始按钮、学习测验页签、带“重做”字样的元素都点过还是没有入口：
// 让 AI 看一遍页面，选一个能让流程继续的操作（比如平台藏在别处的入口）
if (!quizRedoAiTried && typeof app === 'object' && app && typeof app._aiPageRescue === 'function') {
quizRedoAiTried = true;
let aiActed = false;
aiRescueQuizMode = true;
try {
aiActed = await app._aiPageRescue('成绩未达标，但页面找不到重做入口');
} finally {
aiRescueQuizMode = false;
}
if (aiActed) {
// AI 可能选了“跳过/下一节”：这一节已经有安排了，别再刷新页面
if (app._nextUnitPending) return 'no-retry';
// AI 点开的可能是“确定要重做吗”的提示框
await confirmQuizRedoDialog();
await waitForQuizRedoReady();
if (findQuizRedoButton() || quizPaperAnswerable()) continue;
}
}
// 还找不到就别再原地重建页面了：反复重新进节/刷框架正是把渲染进程撑到崩溃的动作。
// 改成整页刷新一次——平台的任务点状态会重新拉取，“重做”入口常常就出来了；
// 同时渲染进程的内存被清零。辅助窗口会在刷新后自动重启脚本。同一节只刷一次。
let reloadLabel = '';
try { reloadLabel = activeSectionKey() || ''; } catch (_) { reloadLabel = ''; }
if (window.__xuexitongKeeperReady === true &&
typeof app === 'object' && app && typeof app._autoRefresh === 'function' &&
quizReloadBudget(reloadLabel, Date.now()) &&
app._autoRefresh('成绩未达标，但页面上找不到重做入口')) {
return 'reloading';
}
const candidates = quizEntryCandidates();
if (candidates.length) console.warn(`%c页面上能点的按钮：${candidates.join('；')}`, 'color:#F44336');
console.error('%c成绩未达标，但页面上确实没有“重做”按钮也没有可重新作答的试卷（平台没有提供重做机会），这一节按已提交处理', 'color:#F44336');
// 记下这一节确实没有重做入口：平台把它带回来时不再重复等 15 秒 + 刷新 + 问 AI
markQuizNoRedo();
return 'no-retry';
}
console.error('%c章节测验重做 24 次仍未通过：答对的题一直照抄，答错的题已经换遍选项，请手动处理这一节', 'color:#F44336');
return 'gave-up';
} finally {
quizRedoActive = false;
}
}

// 重做到头了（同一张试卷原地重交被上限拦住 / 12 轮都没过）：整页刷新一次，
// 用干净的页面和内存重新拿一次任务点状态再试；这一节刚刷新过就不要再刷，免得来回死循环。
async function retrySectionAfterRefresh(reason) {
let label = '';
try { label = activeSectionKey() || ''; } catch (_) { label = ''; }
if (window.__xuexitongKeeperReady === true &&
typeof app === 'object' && app && typeof app._autoRefresh === 'function' &&
quizReloadBudget(label, Date.now()) &&
app._autoRefresh(reason)) {
return true;
}
return false;
}

app._advanceChapterTest = function () {
if (stopped || quizBusy) return;
quizBusy = true;
if (typeof app._noteProgress === 'function') app._noteProgress();
let quizAnswered = false;
(async () => {
// 目录里这一节已经打勾：不管它是纯测验、还是视频+测验混排，整节任务点都已完成，
// 不要再等题目、也不要再提交，直接进下一节（play() 里同一判断会更早拦住，这里兜底直接调用的路径）
if (sectionAlreadyCompleted()) {
console.log('%c这一节在目录里已经打勾（全部任务点已完成），跳过测验直接进入下一节', 'color:#4CAF50');
await goToNextStep();
return;
}
// 成绩未达标、页面停在“请重做”/提示框/上次的成绩页上：接着重做，
// 不能点“下一节”去撞“任务点未完成”弹窗，也不能把成绩页当成新测验再答一遍。
// 但如果平台已经把页面原地变回一份带“提交”按钮、题目齐全、填空能填的试卷（上次的答案
// 还标着对错），那就是“改答案重交”，直接走正常作答，别去等一个永远不会出现的“重做”入口
const earlyPaper = quizPaperAnswerable();
if (earlyPaper) console.log('%c成绩页已经变成可重新作答的试卷，直接改答案重交', 'color:#FF9800');
if (!earlyPaper && quizFailureShown() && (findQuizRedoButton() || quizFailureDialog() || quizPageGraded())) {
console.log('%c这一节的测验成绩未达标，准备重做', 'color:#FF9800');
const redoStatus = await runQuizRedo('成绩未达到及格线');
if (redoStatus === 'memory') {
console.warn(app._refreshing
? '%c页面占用过高，已停止重做；脚本正在自动刷新页面释放内存，刷新后会自动接着做这一节'
: '%c页面占用过高，已停止重做以免标签页崩溃：请按 F5 刷新这个页面，再点一次书签，脚本会接着做完这一节', 'color:#F44336');
return;
}
if (redoStatus === 'reloading') {
console.warn('%c已安排整页刷新来重新获取“重做”入口，辅助窗口会在刷新后自动重启脚本', 'color:#FF9800');
return;
}
if (redoStatus === 'gave-up') {
if (await retrySectionAfterRefresh('这一节重做多次仍未通过，整页刷新后换一份干净状态再试')) return;
console.warn('%c这一节重做多次仍未通过，先跳过；稍后如果平台把它带回来，再手动点一次书签继续', 'color:#F44336');
await skipQuizSection('重做多次仍未通过');
return;
}
if (redoStatus === 'no-retry') {
// 平台死活不给重做入口（等过、也整页刷新过一次）：这份卷子已经交上去了，
// 再停在这里也不会有进展，按“已提交”处理继续下一节；如果平台认为任务点没完成，
// goToNextStep 会被“还有任务点未完成”拉回来，skipQuizSection 会识别并停下
console.warn('%c平台没有提供重做入口，这一节按已提交处理，自动继续下一节', 'color:#FF9800');
await skipQuizSection('成绩未达标，平台没有重做入口');
return;
}
if (redoStatus === 'passed') {
quizBusy = false;
await goToNextStep();
}
return;
}
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
// 目录里标着测验、内容区却是空的（测验已经做完，或这一节没有题目）：
// 这一节不会再有任何内容，以前重试 3 次后停下来等人手动处理，现在直接点“下一节”继续。
if (error.emptyQuizSection) {
quizLoadRetries = 0;
await skipQuizSection('内容是空的');
return;
}
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
// 重试 3 次（约 2 分半）还是没有题目：不再停下等人，跳过这一节继续往下学。
// 真要是一份需要手动做的测验，跳过时平台会弹出“还有任务点未完成”把我们带回来，
// skipQuizSection 会识别出“同一节刚跳过一次”，那时才停下来提示。
console.error('章节测验自动作答停止:', error);
quizLoadRetries = 0;
await skipQuizSection(`等不到题目：${error.message}`);
return;
}
quizLoadRetries = 0;
emptyQuizSkips = 0;
lastSkippedQuiz = { label: '', at: 0 };
if (questions === null) {
console.log('检测到当前章节测验已完成，点击“下一节”进入新视频');
await goToNextStep();
return;
}
// 等题目的过程中平台弹出了“未达到及格线，请重做”：这份卷子其实是上一次的成绩页，
// 每题还带着对错标记，不能再当成新测验作答——交给重做流程换答案。
// 除非页面本身就是一份能重新作答的完整试卷（有提交按钮、题目齐全），那种直接改答案重交
if (quizFailureShown() && quizPageGraded(questions) && !quizPaperAnswerable()) {
console.log('%c这一节显示的是上一次的成绩页，转入重做流程', 'color:#FF9800');
const redoStatus = await runQuizRedo('成绩未达到及格线');
if (redoStatus === 'memory') {
console.warn(app._refreshing
? '%c页面占用过高，已停止重做；脚本正在自动刷新页面释放内存，刷新后会自动接着做这一节'
: '%c页面占用过高，已停止重做以免标签页崩溃：请按 F5 刷新这个页面，再点一次书签，脚本会接着做完这一节', 'color:#F44336');
return;
}
if (redoStatus === 'reloading') {
console.warn('%c已安排整页刷新来重新获取“重做”入口，辅助窗口会在刷新后自动重启脚本', 'color:#FF9800');
return;
}
if (redoStatus === 'gave-up') {
if (await retrySectionAfterRefresh('这一节重做多次仍未通过，整页刷新后换一份干净状态再试')) return;
console.warn('%c这一节重做多次仍未通过，先跳过；稍后如果平台把它带回来，再手动点一次书签继续', 'color:#F44336');
await skipQuizSection('重做多次仍未通过');
return;
}
if (redoStatus === 'no-retry') {
console.warn('%c平台没有提供重做入口，这一节按已提交处理，自动继续下一节', 'color:#FF9800');
await skipQuizSection('成绩未达标，平台没有重做入口');
return;
}
if (redoStatus === 'passed') {
quizBusy = false;
await goToNextStep();
}
return;
}
const textQuestions = questions.textQuestions || [];
const paperTotal = questions.length + textQuestions.length;
if (paperTotal > 30) throw new Error('题目数量超过 30，已停止自动提交');
const paperList = paperQuestions(questions);
const docs = new Set(paperList.map((q) => q.doc));
if (docs.size !== 1) throw new Error('题目跨多个框架，已停止自动提交');
const paperDocument = paperDoc(questions);
const countText = clean(paperDocument.body.innerText).match(/题量\s*[:：]\s*(\d+)/);
const expectedTotal = countText ? Number(countText[1]) : quizHeadingTotal(paperDocument.body);
if (expectedTotal && expectedTotal !== paperTotal)
throw new Error(`页面显示 ${expectedTotal} 道题，脚本只识别 ${paperTotal} 道，已停止提交，避免只答一部分`);
const textSignature = textQuestions.map((q) => `${q.kind}:${q.title}`).join('|');
const signature = questions.map((q) => `${q.kind}:${q.title}`).join('|') + (textSignature ? `|${textSignature}` : '');
// 重做流程自己会换答案再交，不算“重复提交同一份答案”；
// 成绩未达标后平台原地还给一份可作答试卷时，改答案重交也属于正常重做
if (attemptedQuizzes.has(signature) && !quizRedoActive && !quizFailureShown()) throw new Error('本次测验已尝试过，已停止重复提交');
console.log(`识别到 ${paperTotal} 道题${textQuestions.length ? `（选择 ${questions.length} 道，填空/简答 ${textQuestions.length} 道）` : ''}，正在调用 DeepSeek`);
const answers = questions.length ? validateAnswers(questions, await askDeepSeek(questions)) : new Map();
const textAnswers = textQuestions.length ? validateTextAnswers(textQuestions, await askDeepSeekText(textQuestions)) : new Map();
console.table([
...questions.map((q, i) => ({ 题号: i + 1, 题型: q.kind, 选择: (answers.get(i + 1) || []).join(''), 填空: '' })),
...textQuestions.map((q, i) => ({ 题号: questions.length + i + 1, 题型: q.kind, 选择: '', 填空: (textAnswers.get(i + 1) || []).join(' / ') })),
]);
// 平台把上一次的作答留在卷面上时，先清掉已勾选项：多选改答案只点新选项会把旧选项也带上
if (quizFailureShown()) await clearQuizSelections(questions);
await selectAnswers(questions, answers);
await fillTextAnswers(textQuestions, textAnswers);
quizAnswered = true;
attemptedQuizzes.add(signature);
await submitQuiz(paperDocument);
// 交卷后先看结果：平台要求满分时，不合格就重做，别急着点“下一节”
const quizResult = await waitForQuizResult();
if (quizResult.failed) {
console.log('%c成绩未达到及格线，准备重做（答对的保持，答错的换答案）', 'color:#FF9800');
quizAnswerRetries = 0;
const redoStatus = await runQuizRedo('成绩未达到及格线');
if (redoStatus === 'passed') {
quizBusy = false;
await goToNextStep();
}
if (redoStatus === 'memory' || redoStatus === 'reloading') {
console.warn('%c这一节还没做通，但页面占用已经偏高：脚本先刷新页面释放内存，刷新后会自动接着做', 'color:#F44336');
}
if (redoStatus === 'gave-up') {
if (await retrySectionAfterRefresh('这一节重做多次仍未通过，整页刷新后换一份干净状态再试')) return;
console.warn('%c这一节重做多次仍未通过，先跳到下一节；稍后如果平台把它带回来，再手动点一次书签继续', 'color:#F44336');
await skipQuizSection('重做多次仍未通过');
}
return;
}
console.log('章节测验提交已确认，点击“下一节”进入新视频');
quizAnswerRetries = 0;
quizBusy = false;
await goToNextStep();
})().catch((error) => {
app._nextUnitPending = false;
// 调用 AI 失败（服务正忙、接口报错、网络抖动）不代表这一节做不了：
// 隔一会儿重来，别把测验页丢下不管——那样页面就停在原地不动了。
// 已经填过答案的情况不重试，避免同一份测验被重复提交；
// “已停止自动提交/已尝试过”这类是判定结果，重试也不会有变化，直接停。
const permanentStop = /已停止自动提交|已停止重复提交/.test(error.message);
if (!stopped && !app._destroyed && !quizAnswered && !permanentStop && quizAnswerRetries < 3) {
quizAnswerRetries += 1;
console.warn(`%c章节测验作答失败（${error.message}），30 秒后重试（第 ${quizAnswerRetries}/3 次）`, 'color:#FF9800');
setTimeout(() => { if (!stopped && !app._destroyed) app._advanceChapterTest(); }, 30000);
return;
}
quizAnswerRetries = 0;
console.error('章节测验自动作答停止:', error);
if (permanentStop) console.warn('%c这一节的测验已经提交过，但平台仍提示“还有任务点未完成”：请手动打开测验看看成绩有没有生成；脚本不会重复提交同一份答案，不会再动这一节', 'color:#FF9800');
})
.finally(() => { quizBusy = false; });
};

// 手动诊断：在控制台执行 app.inspectQuizRedo()，会列出页面上所有和“重做/测验/任务点”有关的元素。
// 平台以后要是再把入口换到别处，把这张表发出来就能一眼定位新的按钮。
app.inspectQuizRedo = function () {
const rows = [];
for (const doc of courseDocuments()) {
let nodes = [];
try { nodes = Array.from(doc.querySelectorAll('a,button,input,li,dd,dt,div,span,p')); } catch (_) { continue; }
for (const el of nodes) {
let text = '';
try { text = clean(el.innerText || ''); } catch (_) { continue; }
if (!text || text.length > 24 || !/重做|重测|重考|及格|任务点|测验/.test(text)) continue;
let cls = '';
try { cls = String(el.className || '').split(/\s+/).filter(Boolean).slice(0, 2).join('.'); } catch (_) { cls = ''; }
const name = `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ''}${cls ? `.${cls}` : ''}`;
if (!rows.includes(`${name} → ${text}`)) rows.push(`${name} → ${text}`);
if (rows.length >= 40) break;
}
if (rows.length >= 40) break;
}
console.log('%c页面上的重做/测验元素：', 'color:#2196F3');
console.table(rows.map((row) => ({ 元素: row })));
return rows;
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
return findButton(card, label, true);
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
// 这里不再存题目对象：卡片是页面里的 DOM，存下来等于把整道题的节点一直挂在内存里，
// 一节课几十道弹题、连着刷好几天，页面越攒越重（浏览器会先撑不住）
attempts: 0,
tried: [],
// 页面明确判错的答案（和“提交过”分开：提交过但反馈没认出来的答案，之后还可能再选）
wrong: [],
correctBefore: -1,
lastSubmittedAt: 0,
skipCount: 0,
gaveUp: false,
// 放弃的时间：跳节被“还有任务点未完成”弹窗拉回来之后，过一段时间要重新作答，不能一直停着
gaveUpAt: 0,
loggedUnknown: false,
// 上一次提交后页面没有任何判定时，是否已经把原答案原样重提过一次
sameRetried: false,
});
}
return videoQuizStates.get(signature);
}

function videoQuizMaxAttempts(question) {
const count = question && Array.isArray(question.options) ? question.options.length : 0;
if (question && question.kind === '多选题') {
// 多选题：按组合穷举，留足把所有组合试一遍的余地（组合太多时封顶，别真的问到天荒地老）
return Math.min(Math.pow(2, Math.max(count, 2)) - 1, 20);
}
// 单选/判断：每个选项都能试一遍，再留出“提交没被接住、原样重提”和“回头补试”的余量
return Math.max(4, Math.min(10, count * 2 + 2));
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

// —— 弹题提交按钮定位 ——
// 之前只在题目卡片里找文案刚好等于“提交”的元素，平台把按钮叫成“提交作答”、
// 在按钮里塞了图标、或者选完选项后把整块面板重建，都会直接找不到，然后反复报
// “视频弹题中未找到提交按钮”。这里按 由内到外 的顺序找，并且允许重新定位卡片。
const VIDEO_QUIZ_SUBMIT_LABELS = ['提交答案', '提交作答', '确认提交', '确定提交', '提交'];

function submitControlIn(root) {
if (!root || typeof root.querySelectorAll !== 'function') return null;
for (const label of VIDEO_QUIZ_SUBMIT_LABELS) {
const found = findButton(root, label, true);
if (found) return found;
}
const textNode = findTextControl(root, VIDEO_QUIZ_SUBMIT_LABELS);
if (!textNode) return null;
// 文字可能落在按钮里的 span/i 上，往上找到真正的按钮再点
if (/^(BUTTON|A|INPUT)$/.test(textNode.tagName) || textNode.getAttribute('role') === 'button') return textNode;
let control = textNode.parentElement;
for (let depth = 0; control && depth < 3; depth++, control = control.parentElement) {
if (!root.contains(control)) break;
if (/^(BUTTON|A|INPUT)$/.test(control.tagName) || control.getAttribute('role') === 'button') return control;
}
return textNode;
}

function findVideoQuizSubmit(question) {
if (!question || !question.card) return null;
let button = submitControlIn(question.card);
if (button) return button;
// 弹题的提交按钮有时和选项不在同一层（外层浮层/遮罩里），逐级向外找
let scope = question.card;
for (let depth = 0; depth < 6; depth++) {
scope = scope.parentElement;
if (!scope || scope === scope.ownerDocument.body) break;
button = submitControlIn(scope);
if (button) return button;
}
// 最后回到文档里找：只认和这道题共用同一块浮层的提交按钮
const docs = question.doc ? [question.doc] : videoQuizDocuments();
for (const doc of docs) {
for (const candidate of textSubmitCandidates(doc)) {
if (!visible(candidate)) continue;
let node = candidate.parentElement;
for (let depth = 0; node && depth < 8; depth++, node = node.parentElement) {
if (node === doc.body) break;
if (node.contains(question.card)) return candidate;
}
}
}
return null;
}

// 选完选项后卡片可能被平台重建（旧节点虽然 isConnected 为 false，visible() 会直接判死），
// 所以找不到按钮时重新扫一遍弹题，用新的卡片再找一次。
function locateVideoQuizSubmit(question) {
let button = findVideoQuizSubmit(question);
if (button) return { button, question };
const fresh = findVideoQuizCard();
if (fresh && fresh.card !== question.card) {
button = findVideoQuizSubmit(fresh);
if (button) return { button, question: fresh };
}
return { button: null, question };
}

// 平台判完之后的“结果页”：题目面板还在，但“提交”按钮已经换成“继续学习/重新作答”。
// 之前把这种页面当成还在答题，一直循环找提交按钮，三次失败后就暂停跳节。
function videoQuizResultScreen(question) {
if (!question || !question.card) return null;
const text = clean(question.card.innerText || question.card.textContent);
const wrong = isVideoQuizWrong(text);
const success = isVideoQuizSuccess(text);
const correctShown = /正确答案\s*[：:]/.test(text);
if (!wrong && !success && !correctShown) return null;
if (findVideoQuizSubmit(question)) return null;
const retry = findRetryButton(question.card);
const leave = findTextControl(question.card, DISMISS_LABELS) || findVideoQuizContinueButton();
if (!retry && !leave) return null;
return { wrong, success, correctShown, retry, leave, text };
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

// 记下“页面明确判错”的答案，和“提交过”分开存
function markVideoQuizWrongAnswer(state, letters) {
if (!state || !Array.isArray(letters) || !letters.length) return;
if (!Array.isArray(state.wrong)) state.wrong = [];
if (state.wrong.some((entry) => Array.isArray(entry) && sameLetters(entry, letters))) return;
state.wrong.push([...letters]);
}

// 排除法：只排除“页面明确判错”的选项，提交过但没确认错的答案仍然可以再选。
// 以前这里把“提交过的”全都当成不能再用，两个选项（对/错）的题只要第一遍没被
// 识别成通过，第二轮就必然报“所有选项都已尝试过”，然后停下来等人手动做。
function fallbackLetters(question, state) {
const options = question.options.map((option) => option.letter);
if (!options.length) return null;
const tried = (Array.isArray(state.tried) ? state.tried : []).filter((entry) => Array.isArray(entry) && entry.length);
const wrong = (Array.isArray(state.wrong) ? state.wrong : []).filter((entry) => Array.isArray(entry) && entry.length);
if (question.kind !== '多选题') {
// 单选/判断：判错的那一项一定不是答案，剩下的按“没试过的优先”挑一个
const wrongLetters = new Set();
for (const entry of wrong) if (entry.length === 1) wrongLetters.add(entry[0]);
const usable = options.filter((letter) => !wrongLetters.has(letter));
const pool = usable.length ? usable : options;
const untried = pool.filter((letter) => !tried.some((entry) => entry.length === 1 && entry[0] === letter));
return [(untried.length ? untried : pool)[0]];
}
// 多选：把所有非空组合从小到大排好，先避开判错的组合，再优先没试过的组合
const combos = [];
const total = Math.pow(2, options.length);
for (let mask = 1; mask < total; mask++) {
combos.push(options.filter((_, index) => mask & Math.pow(2, index)));
}
combos.sort((a, b) => a.length - b.length || a.join('').localeCompare(b.join('')));
const notWrong = combos.filter((combo) => !wrong.some((entry) => sameLetters(entry, combo)));
const pool = notWrong.length ? notWrong : combos;
const untried = pool.filter((combo) => !tried.some((entry) => sameLetters(entry, combo)));
return (untried.length ? untried : pool)[0] || null;
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
const wrong = (Array.isArray(state.wrong) ? state.wrong : []).filter((entry) => Array.isArray(entry) && entry.length);
if (!tried.length) {
const answers = validateAnswers([question], await askDeepSeek([question]));
return answers.get(1) || fallbackLetters(question, state);
}
// 只有两个选项（判断题/二选一）：页面判错的那一项一定不是答案，直接选另一个。
// 这类题不用再问 AI —— 它很可能把同一个答案再给一遍，白白耗掉作答次数。
if (question.kind !== '多选题' && question.options.length <= 2) {
const deductive = fallbackLetters(question, state);
if (deductive) {
console.log(`%c按排除法作答：${deductive.join('')}`, 'color:#2196F3');
return deductive;
}
}
// 避免重复：优先避开页面判错的答案；还没看到明确判错时，避开已经提交过的
const avoid = wrong.length ? wrong : tried;
const avoidedText = avoid.map((entry) => entry.join('、')).join('；');
const feedback = videoQuizFeedbackText(feedbackText);
const feedbackHint = feedback ? `页面反馈：“${feedback}”。` : '';
const multiHint = question.kind === '多选题' ? '；多选题判错可能是多选了某一项，也可能是漏选了某一项，请逐项重新核对，并选全所有正确项' : '';
// 只提交过、页面没认出来判错的那些，别在提示里说成“判错了”，免得把 AI 带偏
const avoidedLabel = wrong.length ? '已被判为错误' : '已经提交过、页面没有判对';
const hint = `（注意：以下选择${avoidedLabel}：${avoidedText}。${feedbackHint}请重新审题，必须换一个不同于这些的答案${multiHint}。）`;
const hinted = { ...question, title: `${question.title}${hint}`.slice(0, 500) };
let letters = null;
try {
letters = validateAnswers([question], await askDeepSeek([hinted])).get(1);
if (letters && avoid.some((entry) => sameLetters(letters, entry))) letters = null;
} catch (error) {
console.warn('视频弹题重答请求失败，改用排除法:', error);
}
if (!letters) {
// AI 仍给出旧答案时，再问一次，并明确要求“与之前所有尝试不同”
try {
const strictHint = `（这是一道${question.kind}。答案 ${avoidedText} 已经不能再用，必须给出与它不同的答案${multiHint}。）`;
const strict = { ...question, title: `${question.title}${strictHint}`.slice(0, 500) };
const second = validateAnswers([question], await askDeepSeek([strict])).get(1);
if (second && !avoid.some((entry) => sameLetters(second, entry))) {
console.log(`%cAI 重新判断后给出新答案：${second.join('')}`, 'color:#2196F3');
letters = second;
}
} catch (error) {
console.warn('视频弹题第二次重答请求失败，改用排除法:', error);
}
}
if (letters) return letters;
// AI 实在给不出新答案就穷举：单选挨个试、多选按组合试；
// 判错的排除掉，只是提交过、没确认错的仍然可以再试一次。
const fallback = fallbackLetters(question, state);
if (!fallback) throw new Error('弹题没有可选的选项，无法自动作答');
console.log(`%cAI 没有给出新答案，改用穷举：${fallback.join('')}`, 'color:#FF9800');
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

// 目标选项之外、页面还勾着的旧选项
function staleVideoQuizSelections(question, letters) {
const target = new Set(letters || []);
if (!question || !Array.isArray(question.options)) return [];
return question.options.filter((option) => !target.has(option.letter) && videoQuizOptionChecked(option));
}

// 判断题/单选题在有些页面上被画成勾选框，点新选项时旧的不会自己取消：
// 补点一次把它关掉；关不掉就返回剩下的旧选项，由调用处决定不提交
async function clearStaleVideoQuizSelections(question, letters) {
let stale = staleVideoQuizSelections(question, letters);
for (const option of stale) {
const el = option && option.element;
if (!el || !el.isConnected) continue;
try { el.scrollIntoView({ block: 'center' }); } catch (_) { /* 忽略 */ }
// 勾选框可能在选项包装里，也可能在旁边的 label 上：挨个点，点掉了就停
const targets = [];
const addTarget = (target) => {
if (target && !targets.includes(target)) targets.push(target);
};
let input = null;
try { input = el.matches('input') ? el : el.querySelector('input'); } catch (_) { input = null; }
addTarget(input);
addTarget(el);
try { addTarget(el.closest('label') || el.querySelector('label')); } catch (_) { /* 忽略 */ }
for (const target of targets) {
fireClick(target);
await sleep(150);
if (!videoQuizOptionChecked(option)) break;
}
}
stale = staleVideoQuizSelections(question, letters);
return stale;
}

// 章节测验页面上也有“提交”按钮，findVideoQuizCard 会把整张试卷当成弹题卡片。
// 卷面上明确写着“题量：N”，或出现两道以上题型标签时，一律不按弹题处理，
// 否则弹题流程会只选一题的答案就点提交，把整份测验提前交掉。
function looksLikeChapterQuizPaper(question) {
try {
if (!question) return false;
if (typeof app._isChapterTest === 'function' && app._isChapterTest()) return true;
const doc = question.doc || (question.card && question.card.ownerDocument);
if (!doc || !doc.body) return false;
let text = '';
try { text = clean(doc.body.innerText); } catch (_) { return false; }
if (/题量\s*[:：]\s*\d+/.test(text)) return true;
const kinds = text.match(/[\[【](单选题|多选题|判断题|填空题|简答题|论述题|名词解释)[\]】]/g) || [];
return kinds.length >= 2;
} catch (_) { return false; }
}

async function handleVideoQuiz() {
if (stopped || videoQuizBusy || quizBusy || app._isChapterTest()) return;
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
// 找到的“弹题卡片”其实是章节测验试卷：立刻退出，把作答交给章节测验流程
if (looksLikeChapterQuizPaper(question)) {
activeVideoQuiz = null;
videoQuizStuckSince = 0;
app._videoQuizPending = false;
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
// 平台已经判完（显示“真遗憾/正确答案”，提交按钮没了）：不要再循环找提交按钮
const resultScreen = videoQuizResultScreen(question);
if (resultScreen && !attemptedVideoQuizzes.has(signature)) {
if (resultScreen.retry && state.attempts < videoQuizMaxAttempts(question)) {
videoQuizFailures.delete(signature);
state.gaveUp = false;
state.gaveUpAt = 0;
state.sameRetried = false;
state.loggedUnknown = false;
if (resultScreen.wrong) markVideoQuizWrongAnswer(state, state.tried[state.tried.length - 1]);
console.log('%c弹题页面已判错，点击“重新作答”再试一次', 'color:#FF9800');
fireClick(resultScreen.retry);
videoQuizRetryAt = Date.now() + 1500;
return;
}
attemptedVideoQuizzes.add(signature);
app._videoQuizPending = false;
activeVideoQuiz = null;
const shown = shownCorrectLetters(resultScreen.text);
if (shown) console.log(`%c视频弹题页面给出的正确答案：${shown.join('')}`, 'color:#2196F3');
if (resultScreen.leave) {
console.log('%c视频弹题页面已给出判定，点击继续按钮，不再重复作答', 'color:#4CAF50');
fireClick(resultScreen.leave);
videoQuizContinueAt = Date.now();
} else {
console.warn('%c视频弹题结果页没有“继续学习”按钮，先恢复播放，等平台自己收起面板', 'color:#FF9800');
}
if (app._videoEndedDuringQuiz) scheduleVideoEndedNext(1500);
setTimeout(() => {
if (typeof app._resumeAfterVideoQuiz === 'function') app._resumeAfterVideoQuiz();
else if (typeof app._tryResumePlayback === 'function') app._tryResumePlayback('video-quiz-done');
}, 600);
return;
}
if (attemptedVideoQuizzes.has(signature)) {
if (state.gaveUp && state.skipCount < 3) {
state.skipCount++;
skipVideoQuizToNext('已放弃重答');
return;
}
// 跳节也点过了，平台的“还有任务点未完成”弹窗又把页面拉回这一节：
// 不能就这么停住不动，隔一分钟清掉失败计数重新作答（这时排除法通常已经能给出另一个选项）
if (state.gaveUp && Date.now() - (state.gaveUpAt || 0) >= 60000) {
state.gaveUp = false;
state.gaveUpAt = 0;
state.skipCount = 0;
// 作答次数也归零，否则一进来就撞上“已试满次数”又放弃
state.attempts = 0;
state.sameRetried = false;
state.loggedUnknown = false;
videoQuizFailures.delete(signature);
attemptedVideoQuizzes.delete(signature);
console.log('%c这道弹题停顿超过一分钟，重新开始作答（换一个答案再试）', 'color:#FF9800');
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
state.gaveUpAt = Date.now();
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
// 页面明确判错：把上一次提交的答案记下来，之后不再原样重复它
markVideoQuizWrongAnswer(state, state.tried[state.tried.length - 1]);
console.warn('%c检测到上一次回答错误，准备重新作答', 'color:#FF9800');
}
// 上一次提交之后，页面上连“对/错”都没出现：多半是这次提交没被平台接住（按钮没触发、
// 被遮罩挡住、网络慢），而不是答案不对。这种情况换答案等于把可能正确的答案丢掉，
// 所以先按原答案再提交一次；只重提一次，免得在一个交不上去的答案上打转。
const lastTried = state.tried[state.tried.length - 1];
const noFeedbackYet = state.attempts > 0 && Array.isArray(lastTried) && lastTried.length > 0 &&
!isVideoQuizWrong(text) && !(result && result.wrong) && !(result && result.success);
const retrySameAnswer = noFeedbackYet && !state.sameRetried;
if (retrySameAnswer) state.sameRetried = true;
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
activeVideoQuiz = question;
}
}
await clearVideoQuizSelections(question);
question = findVideoQuizCard() || question;
activeVideoQuiz = question;
if (state.attempts === 0 && currentCorrect >= 0) state.correctBefore = currentCorrect;
let letters;
if (retrySameAnswer) {
letters = [...lastTried];
console.log(`%c上一次提交没有看到任何判定结果，先按原答案再提交一次：${letters.join('')}`, 'color:#FF9800');
} else {
letters = await chooseVideoQuizLetters(question, state, shownLetters, text);
}
// 多选：不选的旧选项必须清干净，否则平台的提交里会带上它们；
// 单选/判断是互斥的，点新选项时平台自己会取消旧的，套用这条只会卡住（A 永远取消不掉，就不肯提交 B）
if (question.kind === '多选题' && state.attempts > 0) {
const stale = staleVideoQuizSelections(question, letters);
if (stale.length) throw new Error(`多选题旧选项未能取消（${stale.map((option) => option.letter).join('、')}），暂不提交`);
}
console.log(`%c视频弹题第 ${state.attempts + 1} 次作答：${letters.join('')}`, 'color:#2196F3');
await selectAnswers([question], new Map([[1, letters]]));
if (question.kind !== '多选题') {
const stillStale = await clearStaleVideoQuizSelections(question, letters);
if (stillStale.length) throw new Error(`旧选项未能取消（${stillStale.map((option) => option.letter).join('、')}），暂不提交`);
}
const located = locateVideoQuizSubmit(question);
if (located.question !== question) {
question = located.question;
activeVideoQuiz = question;
}
const submit = located.button;
if (!submit) throw new Error('视频弹题中未找到提交按钮');
try { submit.scrollIntoView({ block: 'center' }); } catch (_) { /* 忽略 */ }
fireClick(submit);
videoQuizFailures.delete(signature);
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
state.gaveUpAt = Date.now();
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
autoMaxSpeed: true,
maxSpeedCandidates: [2, 1.75, 1.5, 1.25],
},
_videoEl: null,
_treeContainerEl: null,
_isPlaying: false,
_noVideoRetryTimes: 0,
_videoQuizActive: false,
_videoQuizPending: false,
_videoEndedDuringQuiz: false,
_quizVideo: null,
_quizSkipAttempts: 0,
_checkInterval: null,
_eventVideoEl: null,
_boundVideoHandlers: null,
_speedStates: null,
_nextUnitPending: false,
_destroyed: false,
_cellData: {
cells: 0,
nCells: 0,
currentCellIndex: 0,
currentNCellIndex: 0,
currentVideoTitle: "",
},
run() {
console.log("%c=== 学习通视频与章节测验助手 V800 启动（多视频版 2026-10-25）===", "color:#4CAF50;font-size:16px;font-weight:bold");
this._installWatchdog();
this._installMemoryGuard();
this._noteProgress();
this._safeStopped = false;
this._nextUnitPending = false;
this._getTreeContainer();
this._initCellData();
console.log(`当前学习步骤：${this._currentStepTitle() || '等待页面加载'}`);
this._videoEl = null;
this._getVideoEl();
this._clearCheckInterval();
this._bindStepNavigation();
this.play();
},
_clearCheckInterval() {
if (this._checkInterval) {
clearInterval(this._checkInterval);
this._checkInterval = null;
}
},
// 重试播放的延时任务：多处都要“先撤掉旧的再安排新的”，统一在这里处理
_clearDelayedNextUnit() {
if (!this._delayedNextUnitTimer) return;
clearTimeout(this._delayedNextUnitTimer);
this._delayedNextUnitTimer = null;
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
this._keepMaxPlaybackRate(video);
this._applyMaxPlaybackRate(video, '播放中').catch(() => {});
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
// 视频在走 ＝ 脚本有进展，停滞自检不介入
if (!stalled) {
this._noteProgress();
this._stallRestarts = 0;
}
if (stalled && stalledMs >= this.configs.guardNoProgressMs) {
// 播放器自己报“无法加载、试试其他线路”时，换线比反复 play() 有用
if (typeof this._retryAlternateVideoLine === 'function' && this._retryAlternateVideoLine('播放停滞')) {
this._guardLastWallTs = now;
this._guardLastTime = Number(video.currentTime || 0);
return;
}
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
_stepSwitchAt: 0,
_stepSwitchPending: false,
_delayedNextUnitTimer: null,
_guardLastTime: 0,
_guardLastWallTs: 0,
_guardLastResumeTs: 0,
_nearEndSince: 0,
async play() {
try {
if (this._destroyed) {
if (!this._destroyedLogged) {
this._destroyedLogged = true;
console.warn('%c本实例已被新注入的脚本接管，旧实例停止工作', 'color:#9E9E9E');
}
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
// 完成情况保险：上一节图文在目录里没打勾就回头补做，避免多篇图文时跳着做漏掉内容
if (typeof this._docProgressAudit === 'function' && this._docProgressAudit()) return;
// 这一节在目录里已经打勾 = 平台认定这一节的全部任务点都完成了（多个视频、多篇图文、
// 视频+测验混排都算在这个勾里）。这种情况不要再从头播一遍视频、也不用再进测验流程，
// 直接进下一节。放在章节测验判断之前：已经做完的测验小节同样按这个勾跳过。
if (typeof this._sectionAlreadyCompleted === 'function' && this._sectionAlreadyCompleted()) {
this._videoEl = null;
this._quizVideo = null;
this._isPlaying = false;
this._allDoneChecks = 0;
this._clearCheckInterval();
console.warn('%c这一节在目录里已经打勾（全部任务点已完成），跳过它直接切换下一节', 'color:#4CAF50');
setTimeout(() => this.nextUnit(), 800);
return;
}
if (this._isChapterTest()) {
this._videoEl = null;
this._isPlaying = false;
this._clearCheckInterval();
this._advanceChapterTest();
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
// 播放器报“无法加载，试试其他线路”时，先点备用线路，干等是不会好的
if (typeof this._retryAlternateVideoLine === 'function' && this._retryAlternateVideoLine('找不到可播放视频')) return;
// 视频任务点刚切过去时，<video> 比页面标题晚一两秒才加载好；
// 这期间不能当成“纯图文”去滚内容区，否则视频会一直停着等人手动点
if (typeof this._waitVideoTaskLoading === 'function' && this._waitVideoTaskLoading()) return;
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
// 这是有意停下的（不是卡住），停滞自检不要在这里反复拉起
this._safeStopped = true;
console.warn('%c当前小节未发现视频或可识别的学习步骤，已安全停止。确认无需完成课件后，可执行 app.nextUnit()。', 'color:#FF9800');
}
return;
}
this._noVideoRetryTimes = 0;
// 页面上确实有视频了，之前的“安全停止”状态作废
this._safeStopped = false;
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
// 这一段视频的任务点平台上已经标成“任务点已完成”：
// 视频本身没播完（从 0 开始重播），但平台已经认这段视频完成了——不要再重播一遍，
// 直接点“下一节”去这一节的下一个任务点（通常是章节测验）。
// 放在“本页视频均已完成”之后：同一任务点里真的还有没播的分段时，上面那段会先去播它们。
if (typeof this._videoTaskPointCompleted === 'function' && this._videoTaskPointCompleted(el)) {
this._videoEl = null;
this._quizVideo = null;
this._isPlaying = false;
this._allDoneChecks = 0;
this._clearCheckInterval();
console.warn('%c当前视频任务点已完成（平台已标记），跳过这段视频，直接进入这一节的下一个任务点', 'color:#4CAF50');
setTimeout(() => this.nextUnit(), 800);
return;
}
this._isPlaying = true;
this._videoEventHandle();
try {
el.muted = true;
el.defaultMuted = true;
el.volume = 0;
// 平台的播放器偶尔会“收下播放请求但永远不回应”（元素已失效、任务点已完成不让重播等）。
// 直接 await 会把整条流程永久卡在这里，对外看起来就是“莫名其妙不动了”，
// 所以最多等 5 秒，超时也继续往下走，交给视频状态检查判断这一页到底什么情况。
const playStarted = await this._playWithTimeout(el, 5000);
this._tryTimes = 0;
this._taskDialogResumes = 0;
if (playStarted) {
console.log('%c视频开始播放', 'color:#4CAF50');
} else {
console.warn('%c视频播放请求 5 秒没有回应（播放器可能已结束或已失效），先继续检查这一页的状态', 'color:#FF9800');
}
this._startVideoMonitoring();
this._applyMaxPlaybackRate(el, '开始播放').catch(() => {});
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
// 播放请求加超时：play() 的 Promise 一直不 settle 时，流程也必须能继续往下走。
// 真播起来了返回 true；超时返回 false；被浏览器拒绝时照常抛出，交给调用处处理。
_playWithTimeout(el, ms) {
return Promise.race([
Promise.resolve().then(() => el.play()).then(() => true),
new Promise((resolve) => setTimeout(() => resolve(false), ms)),
]);
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
// 同时存在多个任务点框架时，按“内容区真正显示的那个”判断，别被预加载的空壳框架带偏
const cardsFrame = displayedCardsFrame();
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
this._clearDelayedNextUnit();
}).catch(e => {
console.error("静音播放也失败:", e);
this._clearDelayedNextUnit();
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
// —— 停滞自检 ——
// 脚本最怕的不是报错，而是“什么都不做也不报错”。这里定期打心跳，
// 并对卡住的流程自动复位；同时把卡住时的现场状态打进控制台，方便回看。
_noteProgress() {
this._lastProgressAt = Date.now();
},
_installWatchdog() {
if (this._watchdogTimer) clearInterval(this._watchdogTimer);
this._lastProgressAt = Date.now();
this._pendingSince = 0;
this._watchdogRestartAt = 0;
this._watchdogTimer = setInterval(() => this._watchdogTick(), 3000);
},
// —— 内存保护 ——
// 每 1 分钟看一眼：内存偏高、或这一页已经连开太久，就整页刷新一次再让辅助窗口重启脚本。
// 这是唯一能真正把渲染进程占用清零的办法（JS 里没有别的释放途径）。
_installMemoryGuard() {
if (this._memoryGuardTimer) clearInterval(this._memoryGuardTimer);
this._bootedAt = this._bootedAt || Date.now();
this._memoryGuardTimer = setInterval(() => this._memoryGuardTick(), 60000);
},
_memoryGuardTick() {
if (this._destroyed || this._refreshing) return;
const now = Date.now();
let heap = 0;
let limit = 0;
try {
const mem = performance.memory;
if (mem) {
heap = Number(mem.usedJSHeapSize) || 0;
limit = Number(mem.jsHeapSizeLimit) || 0;
}
} catch (_) { /* 读不到就不按堆判断，只按运行时长刷新 */ }
let busy = false;
try { busy = typeof this._quizAutomationBusy === 'function' && this._quizAutomationBusy(); } catch (_) { busy = false; }
busy = Boolean(busy || this._videoQuizActive || this._videoQuizPending || docTaskBusy);
if (busy && !this._busySince) this._busySince = now;
if (!busy) this._busySince = 0;
let lastReloadAt = 0;
try { lastReloadAt = Number(PAGE.sessionStorage.getItem('xxtAutoReloadAt')) || 0; } catch (_) { lastReloadAt = 0; }
const decision = memoryRefreshDecision({
now,
heap,
limit,
busy,
busySince: this._busySince,
uptime: now - (this._bootedAt || now),
lastReloadAt,
});
if (!decision) return;
this._autoRefresh(heap > MEMORY_RELOAD_HEAP ? `页面内存占用偏高（JS 堆 ${Math.round(heap / 1048576)} MB）` : '页面已连续运行很久');
},
_autoRefresh(reason) {
if (this._destroyed || this._refreshing) return false;
if (PAGE.__xuexitongKeeperReady !== true) {
console.warn(`%c${reason}，但负责整页刷新后自动重启脚本的辅助窗口不可用，不能自动刷新；请手动按 F5，再点一次“学习通自动答题”书签`, 'color:#F44336');
return false;
}
this._refreshing = true;
try { PAGE.sessionStorage.setItem('xxtAutoReloadAt', String(Date.now())); } catch (_) { /* 忽略 */ }
console.log(`%c${reason}，马上自动刷新页面释放内存；辅助窗口会重新启动脚本，接着当前课程继续`, 'color:#FF9800');
setTimeout(() => {
try {
PAGE.location.reload();
} catch (error) {
this._refreshing = false;
console.warn('自动刷新页面失败，请手动按 F5:', error);
}
}, 800);
return true;
},
// 页面长时间不动时，先让 AI 看一眼再考虑重启/刷新。返回 true 表示“这一轮交给 AI 了”，
// 停滞自检先别再做别的动作（AI 正在识别或刚刚点了东西）。
_aiRescueTick(now) {
if (this._destroyed || this._refreshing) return false;
// 这一节已经确认是“平台不给重做又不让离开”的死结：别再让 AI 反复点下一节
if (typeof this._quizStuckHere === 'function' && this._quizStuckHere()) return false;
if (this._aiRescueRunning) return true;
if (typeof this._aiPageRescue !== 'function') return false;
if (!this._lastProgressAt || now - this._lastProgressAt < AI_RESCUE_IDLE) return false;
// 播放中不算卡住：播放器在走，进度由视频自己推进
let playing = false;
try { playing = typeof this._visibleVideoState === 'function' && this._visibleVideoState().playing; } catch (_) { playing = false; }
if (playing) return false;
// 图文滚动、切换小节、答题/等 AI 结果本来就可能很久，别插一脚
if (docTaskBusy || this._nextUnitPending) return false;
if (this._videoQuizActive || this._videoQuizPending) return false;
if (typeof this._quizAutomationBusy === 'function' && this._quizAutomationBusy()) return false;
const rescue = this._aiPageRescue(`已经 90 秒没有任何进展（步骤：${this._currentStepTitle() || '未识别'}）`);
// aiPageRescue 的冷却/次数上限是在第一个 await 之前同步判断的：没真正开始就别拦着停滞自检
if (this._aiRescueRunning !== true) return false;
rescue.then((acted) => {
if (!acted || this._destroyed || this._refreshing) return;
if (typeof this._quizAutomationBusy === 'function' && this._quizAutomationBusy()) return;
// AI 点过东西之后，让播放器重新识别页面，接着走正常的答题/播放流程
setTimeout(() => {
if (this._destroyed || this._nextUnitPending) return;
try { this.play(); } catch (_) { /* 忽略 */ }
}, 1500);
}).catch(() => { /* aiPageRescue 自己会打日志 */ });
return true;
},
_watchdogTick() {
try {
if (this._destroyed) {
if (this._watchdogTimer) clearInterval(this._watchdogTimer);
this._watchdogTimer = null;
return;
}
const now = Date.now();
// 给辅助窗口一个“脚本还活着”的信号：JS 线程真死了心跳才会停
try { PAGE.__xuexitongLastBeat = now; } catch (_) { /* 忽略 */ }
// 已经停在这一节等待手动处理：不再重启/自动跳节，避免反复刷屏
if (typeof this._quizStuckHere === 'function' && this._quizStuckHere()) return;
if (docTaskBusy) {
if (docTaskBusySince && now - docTaskBusySince > 20000) {
docTaskBusy = false;
docTaskBusySince = 0;
console.warn('%c图文滚动卡住超过 20 秒，已自动解除占用并重新识别页面', 'color:#FF9800');
this._watchdogRestart('图文滚动卡住');
return;
}
} else if (docTaskBusySince) {
docTaskBusySince = 0;
}
if (this._nextUnitPending) {
if (!this._pendingSince) this._pendingSince = now;
if (now - this._pendingSince > 150000) {
this._nextUnitPending = false;
this._pendingSince = 0;
console.warn('%c切换小节卡住超过 150 秒，已自动复位并重新识别页面', 'color:#FF9800');
this._watchdogRestart('切换小节卡住');
return;
}
} else if (this._pendingSince) {
this._pendingSince = 0;
}
if (!this._lastProgressAt) { this._lastProgressAt = now; return; }
if (this._safeStopped) return;
if (now - this._lastProgressAt < 75000) return;
if (this._watchdogRestartAt && now - this._watchdogRestartAt < 60000) return;
// 75 秒没进展：先让 AI 识别页面并试着操作；它选“等待”或做不了时，再走原来的重启逻辑
if (this._aiRescueTick(now)) return;
// 这些阶段本来就慢（等题目、等 DeepSeek、等测验页、等视频），不算卡住
if (this._isChapterTest()) {
// 答题流程还在跑（等题目、等 DeepSeek、交卷）本来就可能很久，绝不能打断
if (typeof this._quizAutomationBusy === 'function' && this._quizAutomationBusy()) return;
// 测验页不是永远不能碰：答题流程其实空闲太久，就按卡住处理重新识别页面；
// 连续几次后停滞自检会跳到下一节，不会永远停在这一页
if (now - this._lastProgressAt >= 120000) {
console.warn(`%c章节测验页已经 ${Math.round((now - this._lastProgressAt) / 1000)} 秒没有任何动作，重新识别页面`, 'color:#FF9800');
this._watchdogRestart('章节测验页没有响应');
}
return;
}
if (this._videoQuizActive || this._videoQuizPending) return;
if (typeof this._quizAutomationBusy === 'function' && this._quizAutomationBusy()) return;
let playing = false;
try { playing = typeof this._visibleVideoState === 'function' && this._visibleVideoState().playing; } catch (_) { playing = false; }
if (playing) { this._lastProgressAt = now; return; }
let videos = 0;
let docs = 0;
let step = '';
try { videos = this._findAllVideos().length; } catch (_) { videos = 0; }
try { docs = typeof this._contentFrameDocs === 'function' ? this._contentFrameDocs().length : 0; } catch (_) { docs = 0; }
try { step = this._currentStepTitle() || ''; } catch (_) { step = ''; }
console.warn(`%c已经 75 秒没有任何进展（步骤：${step || '未识别'}，视频 ${videos} 个，图文框架 ${docs} 个，切换中：${this._nextUnitPending ? '是' : '否'}，图文占用：${docTaskBusy ? '是' : '否'}），自动重新识别页面继续`, 'color:#FF9800');
this._watchdogRestart('长时间无进展');
} catch (error) {
if (!this._watchdogErrorAt || Date.now() - this._watchdogErrorAt > 60000) {
this._watchdogErrorAt = Date.now();
console.warn('停滞自检出错，已忽略:', error && error.message ? error.message : error);
}
}
},
_watchdogRestart(reason) {
if (this._destroyed) return;
this._watchdogRestartAt = Date.now();
this._lastProgressAt = Date.now();
this._tryTimes = 0;
this._noVideoRetryTimes = 0;
this._allDoneChecks = 0;
this._videoLoadWaitSince = 0;
this._stepSwitchPending = false;
// “重新识别页面”就要连播放器元素一起重新找：抱着旧元素重启，只会用同一个失效元素再卡一次
this._videoEl = null;
this._quizVideo = null;
this._clearCheckInterval();
try { this._initCellData(); } catch (_) { /* 目录还没准备好时忽略 */ }
// 连着几次重启都没有进展，说明反复 play() 解决不了，得换一招
this._stallRestarts = (this._stallRestarts || 0) + 1;
const skipPage = this._stallRestarts >= 3;
console.log(`%c停滞自检：已重新识别页面（${reason}）`, 'color:#607D8B');
setTimeout(() => {
if (this._destroyed) return;
this._noteProgress();
if (skipPage) {
this._stallRestarts = 0;
console.warn('%c这一页连续 3 次没有任何进展，先跳到下一节继续；如果这一节确实还没完成，稍后手动回来检查', 'color:#F44336');
this.nextUnit();
return;
}
this.play();
}, 1200);
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
// 平台说这一页还有任务点没完成：把“已读过”的标记清掉，回去重新读一遍
if (typeof this._resetDocReading === 'function') this._resetDocReading();
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
// 旧播放器元素还挂在页面上，但既看不见、也播不动，而页面上唯一可见的视频已经播完：
// _nextPlayableVideo 会把“播完的视频”排除掉，于是这里一直抱着那个死元素，
// play() 对它发起的播放请求永远没有回应 —— 表现出来就是整页卡死不再前进。
// 页面上还有可见视频就用它，播没播完交给 play() 判断（播完就走“已完成”流程）。
let visibleVideo = null;
try {
visibleVideo = this._findAllVideos(false).find((video) => video !== this._videoEl) || null;
} catch (_) { visibleVideo = null; }
if (visibleVideo) {
console.log('%c旧播放器已失效，改用页面上可见的视频', 'color:#4CAF50');
// 把这个换下来的死元素记为“已完成”，否则后面找“下一段视频”时还会把它翻出来，来回打转
this._markVideoDone(this._videoEl);
this._videoEl = visibleVideo;
try {
visibleVideo.muted = true;
visibleVideo.defaultMuted = true;
visibleVideo.volume = 0;
} catch (_) {}
return visibleVideo;
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
// —— 自动最高倍速：能调就调到最高，调不动就放弃 ——
_speedCandidates() {
const configured = Array.isArray(this.configs.maxSpeedCandidates) ? this.configs.maxSpeedCandidates : [];
const list = configured
.map((value) => Number(value))
.filter((value) => Number.isFinite(value) && value > 1);
if (!list.length) return [2, 1.75, 1.5, 1.25];
return list.sort((a, b) => b - a);
},
_readPlaybackRate(video) {
try { return Number(video.playbackRate) || 0; } catch (_) { return 0; }
},
_speedStateOf(video) {
if (!this._speedStates) this._speedStates = new Map();
let state = this._speedStates.get(video);
if (!state) {
state = { src: '', applied: 0, busy: false, givenUp: false, drift: 0, lastTryAt: 0 };
this._speedStates.set(video, state);
}
// 同一个播放器换了视频源时重新判断，别沿用上一段的结论
const src = this._videoSrcOf(video);
if (state.src !== src) {
state.src = src;
state.applied = 0;
state.busy = false;
state.givenUp = false;
state.drift = 0;
state.lastTryAt = 0;
}
return state;
},
async _applyMaxPlaybackRate(video, reason) {
if (!video || this._destroyed) return 0;
if (!this.configs || this.configs.autoMaxSpeed === false) return 0;
const state = this._speedStateOf(video);
if (state.givenUp) return 0;
const current = this._readPlaybackRate(video);
if (state.applied && current >= state.applied - 0.01) return state.applied;
if (state.busy) return state.applied;
if (Date.now() - state.lastTryAt < 2500) return state.applied;
state.busy = true;
state.lastTryAt = Date.now();
try {
for (const target of this._speedCandidates()) {
let wrote = false;
try {
video.defaultPlaybackRate = target;
video.playbackRate = target;
wrote = true;
} catch (_) {
wrote = false;
}
// 赋值被拒绝、或被浏览器夹到别的数值，换低一档再试
if (!wrote || Math.abs(this._readPlaybackRate(video) - target) > 0.01) continue;
await sleep(600);
if (this._destroyed || !video.isConnected) return 0;
// 设置后 0.6 秒仍保持不变才算真的可调
if (Math.abs(this._readPlaybackRate(video) - target) <= 0.01) {
state.applied = target;
state.drift = 0;
console.log(`%c视频已调到最高 ${target}x 倍速${reason ? `（${reason}）` : ''}`, 'color:#4CAF50');
return target;
}
}
state.givenUp = true;
state.applied = 0;
try {
video.defaultPlaybackRate = 1;
video.playbackRate = 1;
} catch (_) {}
console.log('%c这个视频不允许调倍速（设置后会被还原），保持默认速度', 'color:#9E9E9E');
return 0;
} finally {
state.busy = false;
}
},
_keepMaxPlaybackRate(video) {
if (!video || this._destroyed) return;
const state = this._speedStateOf(video);
if (state.givenUp || !state.applied || state.busy) return;
if (this._readPlaybackRate(video) >= state.applied - 0.01) {
state.drift = 0;
return;
}
// 播放器中途把倍速改回默认：先补回来，连续多次被改回去就判定不可调
state.drift += 1;
if (state.drift >= 4) {
state.givenUp = true;
state.applied = 0;
console.log('%c播放器反复把倍速改回默认，判定这个视频不可调倍速，保持默认速度', 'color:#9E9E9E');
return;
}
try { video.playbackRate = state.applied; } catch (_) {}
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
this._applyMaxPlaybackRate(this._videoEl, '加载完成').catch(() => {});
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
this._applyMaxPlaybackRate(video, '开始播放').catch(() => {});
this._clearDelayedNextUnit();
},
_handleVideoPause(e) {
console.log(`%c============视频暂停=============`, "color:#FF9800");
},
_bindPageGuards() {
const preventPause = (e) => {
// 只看“真的移出页面/窗口”的情况：鼠标在页面内部从一个元素移到另一个元素也会触发
// mouseout，以前每次都被拦掉，既费性能又会影响平台自己的悬停菜单。
const to = e && e.relatedTarget;
if (to && to.nodeType === 1 && document.contains(to)) return;
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
if (this._watchdogTimer) {
clearInterval(this._watchdogTimer);
this._watchdogTimer = null;
}
if (this._memoryGuardTimer) {
clearInterval(this._memoryGuardTimer);
this._memoryGuardTimer = null;
}
this._clearDelayedNextUnit();
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

// 启动失败不能一死了之：页面这时常常还在渲染（比如刚整页跳转到新章节），
// 间隔几秒重试一般就能正常启动。
let bootFailures = 0;
const bootUp = () => {
try {
app.run();
app._bindPageGuards();
} catch (error) {
bootFailures += 1;
console.error("%c脚本运行失败: ", "color:#F44336;font-weight:bold", error);
if (bootFailures >= 10) {
console.log("已重试 10 次仍未启动，请检查是否在正确的课程播放页面，或者页面结构是否再次发生改变。");
return;
}
console.warn(`%c3 秒后自动重试启动（第 ${bootFailures}/10 次）`, 'color:#FF9800');
setTimeout(() => {
if (PAGE[APP_KEY] !== app) return;
bootUp();
}, 3000);
}
};
bootUp();
}
})();
:__XXT_BROWSER_END__
