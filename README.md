# 学习通 DeepSeek 助手（控制台版）

一个运行在本机的学习通课程辅助脚本：自动播放视频、回答章节测验、处理视频中途弹题、自动切换下一节，并在遇到“暂无内容”的空小节时自动跳过。

本项目基于 GitHub 开源项目 **xuexitongScript** 二次修改（二改），原项目版权归原作者所有。

## 功能

- 自动播放课程视频，视频结束后进入下一学习步骤
- 自动识别章节测验中的单选题、多选题、判断题，调用 DeepSeek API 作答并提交
- 识别视频播放中途弹出的题目，自动作答；答错后自动重新作答，答对后自动点击“继续学习”恢复播放
- 全页面扫描题目与选项，兼容多种页面结构
- 视频卡住时自动恢复播放，找不到视频时自动重试
- DeepSeek 输出被截断时自动降级重试，不会提交残缺答案
- 大章节显示“暂无内容”时自动点击“下一节”跳过，最多连续跳过 10 个
- 页面整页跳转后通过辅助窗口自动恢复脚本

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `start-local-service.cmd` | 启动本地服务，并打开可视化设置页输入 DeepSeek API Key |
| `deepseek-local.mjs` | 本地 HTTP 服务（`127.0.0.1:37841`），校验令牌并转发答题请求 |
| `deepseek-request.mjs` | 调用 DeepSeek Chat Completions API 的答题逻辑 |
| `xuexitong-console.js` | 注入学习通课程页面的自动化脚本 |

四个文件必须放在同一个文件夹内。

## 环境要求

- Windows 10 / 11
- Microsoft Edge
- [Node.js](https://nodejs.org) LTS 版本
- DeepSeek API Key（[platform.deepseek.com](https://platform.deepseek.com) 注册后创建，API 为按量付费）

## 使用方法

1. 双击 `start-local-service.cmd`。会弹出一个可视化的设置窗口，粘贴 DeepSeek API Key，勾选“记住密钥”后点击“保存并启动”。
   黑色命令行窗口会继续保留用于显示日志和停止服务，但不再需要在那里输入 Key。
2. 如果没有自动弹出设置窗口，用浏览器打开 `http://127.0.0.1:37841/setup`。
3. 用 Edge 登录学习通，进入课程播放页（地址包含 `/mycourse/studentstudy`）。
4. 用记事本打开 `xuexitong-console.js`，全选复制。
5. 在课程页按 `F12` 打开控制台（Console），粘贴脚本并按 Enter。
6. 浏览器询问是否允许访问本地网络时选择“允许”；脚本弹出的辅助窗口不要关闭。

脚本启动后会自动开始播放与答题。

### 方式二：用书签启动（可选，不用每次复制脚本）

本地服务还提供 `http://127.0.0.1:37841/script`。书签每次点击都会拉取本次启动、已注入新令牌的脚本，所以服务重启后也不需要修改书签。

1. 确认本地服务已在运行（`start-local-service.cmd` 窗口不要关）。
2. 在 Edge 按 `Ctrl+Shift+O` 打开收藏夹管理，添加一个新收藏夹。
3. 名称填“学习通自动答题”，网址填下面这一整行（必须以 `javascript:` 开头）：

```javascript
javascript:(async()=>{try{const r=await fetch('http://127.0.0.1:37841/script',{cache:'no-store'});if(!r.ok)throw new Error('HTTP '+r.status);const s=document.createElement('script');s.textContent=await r.text();document.documentElement.appendChild(s);s.remove()}catch(e){alert('注入失败：'+e.message)}})()
```

4. 打开学习通课程播放页，点击书签即可注入，不需要按 `F12`。
5. 如果点击后没有反应，可能是页面 CSP 拦截了内联脚本，改用上面的复制粘贴方式。

## 密钥记忆

- 勾选“记住密钥”后，Key 会使用 Windows 当前用户的 DPAPI 加密，保存在 `%APPDATA%\xuexitong-deepseek\config.json`，下次启动自动加载，无需重新输入。
- 需要更换或删除时，打开 `http://127.0.0.1:37841/setup`，输入新 Key 或点击“清除已保存的密钥”。
- 不勾选“记住密钥”时，Key 只在本次运行期间保留，不写入磁盘。

## 注意事项

- 每次重新启动本地服务后，脚本中的临时令牌都会更新，需要重新复制一次 `xuexitong-console.js` 再粘贴。
- 本地服务只监听 `127.0.0.1`；勾选“记住密钥”时 Key 会加密保存在本机，答题内容会发送至 DeepSeek API。
- 使用 API 会产生费用；AI 可能答错；自动化操作可能触发平台风控。
- 如果页面出现“已在调试程序中暂停”，在开发者工具中按 `F8` 恢复，或在 Sources 面板关闭“遇到异常时暂停”。

## 免责声明

- 本项目仅供技术学习与交流，请勿用于任何违反学校、平台规定或法律法规的用途。
- 本项目为开源项目二次修改，原项目版权归原作者所有；本版本免费分享，禁止任何形式的收费、倒卖或商业用途。
- 使用本项目产生的一切后果由使用者自行承担；请遵守所在学校和平台的规定。
- 如有侵权，请联系作者删除。
