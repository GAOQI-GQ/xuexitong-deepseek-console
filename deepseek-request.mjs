const API_URL = 'https://api.deepseek.com/chat/completions';
const ATTEMPTS = [
    { thinking: { type: 'enabled' }, reasoning_effort: 'low', max_tokens: 16000 },
    { thinking: { type: 'disabled' }, max_tokens: 8000 },
];

export async function requestAnswers(questions, apiKey, fetchImpl = fetch) {
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
