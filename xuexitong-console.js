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
console.error('请先启动 DeepSeek 本地服务，再复制更新后的 xuexitong-console.js');
return;
}

const previousApp = PAGE[APP_KEY];
if (previousApp && typeof previousApp.destroy === 'function') {
previousApp.destroy();
}
if (PAGE.__xuexitongPlayerV3 && typeof PAGE.__xuexitongPlayerV3.destroy === 'function') {
PAGE.__xuexitongPlayerV3.destroy();
}
if (PAGE.__xuexitongPlayerV4DeepSeek && typeof PAGE.__xuexitongPlayerV4DeepSeek.destroy === 'function') {
PAGE.__xuexitongPlayerV4DeepSeek.destroy();
}
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
document.head.appendChild(script);
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
keeper.document.body.innerHTML = '<p style="font:16px sans-serif;padding:12px">学习通自动任务正在运行。请保持此窗口打开；课程页整页跳转后，它会重新启动脚本。</p>';
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
let videoQuizBusy = false;
let videoQuizTimer = null;
let videoQuizRetryAt = 0;
let stopped = false;
const originalDestroy = app.destroy.bind(app);
app.destroy = function () {
stopped = true;
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

function quizCompleted() {
const scoreShown = courseDocuments().some((doc) => {
const text = clean(doc.body?.innerText);
const hasGrade = /本次成绩\s*\d+(?:\.\d+)?\s*分/.test(text);
return hasGrade && (/章节测验\s*已完成/.test(text) || /我的答案\s*[:：]/.test(text));
});
if (scoreShown) return true;
const cardsFrame = Array.from(document.querySelectorAll('iframe[src*="/knowledge/cards"]'))
.find((frame) => frame.getClientRects().length > 0);
const isQuizStep = cardsFrame && new URL(cardsFrame.getAttribute('src'), location.href).searchParams.get('num') === '1';
return Boolean(isQuizStep && document.querySelector('.posCatalog_active .icon_Completed'));
}

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

function findNextButton() {
for (const doc of courseDocuments()) {
const known = doc.querySelector('#prevNextFocusNext, #right1, .nextChapter');
if (visible(known) && clean(known.innerText || known.title).includes('下一节')) return known;
const generic = findButton(doc, '下一节');
if (generic) return generic;
}
return null;
}

async function revealQuizQuestions() {
const docs = courseDocuments();
const submit = docs.map((doc) => findButton(doc, '提交')).find(Boolean);
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

async function waitForQuizQuestions() {
let submitDoc = null;
for (let attempt = 0; attempt < 240; attempt++) {
if (stopped) throw new Error('脚本已停止');
if (quizCompleted()) return null;
submitDoc = courseDocuments().find((doc) => findButton(doc, '提交'));
if (submitDoc) break;
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
const submit = findButton(doc, '提交');
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
if (elapsedHalfSeconds % 30 === 0) console.log(`成绩页仍在加载，已等待 ${elapsedHalfSeconds / 2} 秒`);
}
throw new Error('脚本已停止');
}

async function goToNextStep() {
if (stopped) throw new Error('脚本已停止');
if (!findNextButton()) throw new Error('未找到页面下方的“下一节”按钮');
app._nextUnitPending = true;
const previousStep = app._currentStepTitle();
const previousVideo = app._getVideoEl();
const previousSrc = previousVideo ? (previousVideo.currentSrc || previousVideo.src || '') : '';
app._clearCheckInterval();
app._videoEl = null;
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
currentStep = app._currentStepTitle();
if (currentStep === '章节测验' && currentStep !== previousStep) {
stepReady = true;
break;
}
const video = app._getVideoEl();
if (video) {
const src = video.currentSrc || video.src || '';
if (video !== previousVideo || (src && src !== previousSrc)) {
stepReady = true;
break;
}
}
if (pageShowsNoContent()) {
if (!emptySince) emptySince = Date.now();
} else {
emptySince = 0;
}
const waited = Date.now() - clickedAt;
const emptyFor = emptySince ? Date.now() - emptySince : 0;
const emptyConfirmed = emptyFor >= 6000 || (currentStep === '视频' && !video && waited >= 45000);
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

app._advanceChapterTest = function () {
if (stopped || quizBusy) return;
quizBusy = true;
(async () => {
if (quizCompleted()) {
console.log('检测到当前章节测验已完成，点击“下一节”进入新视频');
await goToNextStep();
return;
}
console.log('已进入章节测验，等待题目和提交按钮加载');
const questions = await waitForQuizQuestions();
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
const video = typeof app._getVideoEl === 'function' ? app._getVideoEl() : null;
if (video && video.ownerDocument) add(video.ownerDocument);
for (const doc of courseDocuments()) add(doc);
add(document);
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
const candidates = Array.from(card.querySelectorAll('button,a,input[type="button"],input[type="submit"],[role="button"],div,span'))
.filter((el) => visible(el) && clean(el.value || el.innerText) === label);
return candidates.find((el) => /^(BUTTON|A|INPUT)$/.test(el.tagName)) ||
candidates.find((el) => !Array.from(el.children).some((child) => clean(child.innerText) === label)) || null;
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
videoQuizStates.set(signature, { attempts: 0, tried: [], correctBefore: -1, lastSubmittedAt: 0 });
}
return videoQuizStates.get(signature);
}

function correctCount(text) {
const match = String(text || '').match(/已答对\s*(\d+)\s*题/);
return match ? Number(match[1]) : -1;
}

function isVideoQuizSuccess(text) {
return /您的回答正确|回答正确[！!。\s]|回答正确$|答案正确[！!。\s]|答案正确$|答对了[！!。\s]|答对了$|恭喜.*正确/.test(text);
}

function isVideoQuizWrong(text) {
return /回答错误|答错了|答案错误|回答不正确|请重新作答|重新作答|再试一次|重新回答|再次作答/.test(text);
}

function findRetryButton(card) {
for (let scope = card, depth = 0; scope && depth < 3; depth++, scope = scope.parentElement) {
for (const label of ['重新回答', '重新作答', '重新答题', '再次作答', '再试一次', '重新选择', '重试', '继续作答', '重做']) {
const button = findButtonIn(scope, label);
if (button) return button;
}
}
return null;
}

function dismissVideoQuiz(card) {
for (let scope = card, depth = 0; scope && depth < 3; depth++, scope = scope.parentElement) {
for (const label of ['继续播放', '继续', '下一题', '知道了', '关闭', '确定']) {
const button = findButtonIn(scope, label);
if (button) {
button.click();
return true;
}
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

async function chooseVideoQuizLetters(question, state, shownLetters) {
if (shownLetters && shownLetters.length && shownLetters.every((letter) => question.options.some((option) => option.letter === letter))) {
const letters = question.kind === '多选题' ? shownLetters : [shownLetters[0]];
console.log(`%c使用页面提示的正确答案：${letters.join('')}`, 'color:#4CAF50');
return letters;
}
const last = state.tried[state.tried.length - 1];
if (!last) {
const answers = validateAnswers([question], await askDeepSeek([question]));
return answers.get(1);
}
const hint = `（注意：上一次选择 ${last.join('、')} 被判为错误，请换一个不同的答案，不要重复上次的选择。）`;
const hinted = { ...question, title: `${question.title}${hint}`.slice(0, 500) };
let letters = null;
try {
letters = validateAnswers([question], await askDeepSeek([hinted])).get(1);
if (letters && sameLetters(letters, last)) letters = null;
} catch (error) {
console.warn('视频弹题重答请求失败，改用排除法:', error);
}
if (letters) return letters;
const fallback = fallbackLetters(question, state);
if (!fallback) throw new Error('所有选项都已尝试过，仍未答对，请手动完成');
return fallback;
}

async function handleVideoQuiz() {
if (stopped || videoQuizBusy || app._isChapterTest() || app._nextUnitPending) return;
if (Date.now() < videoQuizRetryAt) return;
let question = findVideoQuizCard();
if (!question) return;
const video = typeof app._getVideoEl === 'function' ? app._getVideoEl() : null;
if (video && !video.paused) {
try { video.pause(); } catch (_) { /* 忽略 */ }
}
const signatureTitle = question.title
.replace(/回答(?:错误|正确)[\s\S]*$/, '')
.replace(/正确答案\s*[：:][A-H\s、,，]*/g, '')
.trim();
const signature = `${question.kind}:${signatureTitle}:${question.options.map((option) => `${option.letter}${option.text}`).join('|')}`;
if (attemptedVideoQuizzes.has(signature)) return;
const state = videoQuizState(signature);
const text = clean(question.card.innerText);
const currentCorrect = correctCount(text);
const successByCounter = state.correctBefore >= 0 && currentCorrect > state.correctBefore;
const successByText = state.attempts > 0 && isVideoQuizSuccess(text);
if (successByCounter || successByText) {
attemptedVideoQuizzes.add(signature);
console.log('%c视频弹题回答正确', 'color:#4CAF50');
videoQuizBusy = true;
app._videoQuizActive = true;
try {
dismissVideoQuiz(question.card);
} finally {
videoQuizBusy = false;
app._videoQuizActive = false;
}
return;
}
if (state.attempts >= MAX_VIDEO_QUIZ_ATTEMPTS) {
attemptedVideoQuizzes.add(signature);
console.error(`视频弹题已尝试 ${state.attempts} 次仍未通过，请手动完成`);
return;
}
if (state.attempts > 0 && isVideoQuizWrong(text)) {
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
}
}
if (state.attempts === 0 && currentCorrect >= 0) state.correctBefore = currentCorrect;
const letters = await chooseVideoQuizLetters(question, state, shownLetters);
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
attemptedVideoQuizzes.add(signature);
console.error(`视频弹题自动作答失败（已尝试 ${failures} 次），请手动完成:`, error);
} else {
videoQuizRetryAt = Date.now() + 5000;
console.error(`视频弹题自动作答失败（第 ${failures} 次），5 秒后重试:`, error);
}
} finally {
videoQuizBusy = false;
app._videoQuizActive = false;
}
}

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
if (stopped || videoQuizBusy) return;
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
_checkInterval: null,
_eventVideoEl: null,
_boundVideoHandlers: null,
_nextUnitPending: false,
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
console.log("%c=== 学习通视频与章节测验助手 V4 启动 ===", "color:#4CAF50;font-size:16px;font-weight:bold");
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
if (this._videoQuizActive) return;
const now = Date.now();
if (now - this._guardLastResumeTs < this.configs.guardResumeCooldownMs) {
return;
}
this._guardLastResumeTs = now;
const video = this._getVideoEl();
if (!video || !this._isPlaying) return;
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
_checkVideoStatus() {
if (this._videoQuizActive) return;
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
setTimeout(() => this.nextUnit(), 1000);
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
async play() {
try {
if (this._isChapterTest()) {
this._videoEl = null;
this._isPlaying = false;
this._clearCheckInterval();
this._advanceChapterTest();
return;
}
const el = this._getVideoEl();
if (el == null) {
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
this._isPlaying = true;
this._videoEventHandle();
try {
el.muted = true;
el.defaultMuted = true;
el.volume = 0;
await el.play();
this._tryTimes = 0;
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
$(document).off('click.xuexitongPlayerV4', '.prev_white').on('click.xuexitongPlayerV4', '.prev_white', (e) => {
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
if (!this._treeContainerEl) {
const el = $('#coursetree');
if (el.length <= 0) {
throw new Error("找不到视频列表");
}
this._treeContainerEl = el;
}
return this._treeContainerEl;
},
_getVideoEl() {
if (!this._videoEl) {
try {
const findVideo = (frame, depth) => {
if (depth > 2) return null;
const frameDocument = frame.contentDocument || frame.contentWindow?.document;
if (!frameDocument) return null;
const $frameDocument = $(frameDocument);
const directVideo = $frameDocument.find('video#video_html5_api, video[id*="video_html5"]').get(0);
if (directVideo) return directVideo;
const nestedFrames = $frameDocument.find('iframe.ans-insertvideo-online, iframe[src*="video"]');
for (const nestedFrame of nestedFrames.toArray()) {
const nestedVideo = findVideo(nestedFrame, depth + 1);
if (nestedVideo) return nestedVideo;
}
return null;
};
for (const frame of $('iframe').toArray()) {
const video = findVideo(frame, 0);
if (video) {
this._videoEl = video;
video.muted = true;
video.defaultMuted = true;
video.volume = 0;
break;
}
}
} catch (e) {
console.error("获取视频元素失败:", e);
return null;
}
}
if (!this._videoEl) return null;
return this._videoEl;
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
const title = this._cellData.currentVideoTitle;
console.warn(`%c============'${title}' 播放完成=============`, "color:#4CAF50;font-weight:bold");
this._isPlaying = false;
this._clearCheckInterval();
setTimeout(() => this.nextUnit(), 1000);
},
_handleVideoLoaded(e) {
console.log(`%c============视频加载完成=============`, "color:#2196F3");
if (this.configs.autoplay && !this._isPlaying) {
this.play();
}
},
_handleVideoPlay(e) {
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
$(document).off('.xuexitongPlayerV4');
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
