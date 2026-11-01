# 隐私说明 · Privacy

## 中文

**模型会收到什么？** 处理自然语言请求或生成界面时，Orvlet 会将相关请求、对话和网页内容发送给你在设置中选择的模型服务。内容可能包括网页标题、地址、文字和操作按钮；开启视觉输入并使用截图时，也可能包含网页截图。请留意所使用模型服务的隐私政策。

**什么留在本机？** 模型密钥保存在 macOS Keychain。设置、任务记录、最近访问的网页和生成的界面保存在本机。计时更新、直接播放控制、窗口移动和透明度变化本身不调用模型。

**网页和日历呢？** 原网页仍会正常联网并使用自己的 Cookie。广告过滤不能阻止所有追踪。日程只在获得系统授权后写入 Apple 日历，关闭结果卡片不会删除事件。

**可选连接有什么影响？** 本机连接默认关闭。开启并配对外部浏览器或 agent 后，对方可以通过支持的操作读取网页、查询历史和控制任务。只连接你信任的客户端，不要分享配对码。

你可以在设置中关闭本机连接、会话恢复或广告过滤。关闭任务会释放其运行中的网页，但不会自动清除所有历史和网站数据。目前尚无一键清除全部数据的入口。

## English

**What reaches the model?** Natural-language assistance and interface generation send relevant requests, conversation, and page content to the model provider you choose in Settings. This may include page titles, URLs, text, and controls. With visual input enabled, requested webpage screenshots may also be sent. Review your provider's privacy policy.

**What stays on this Mac?** API keys are stored in macOS Keychain. Settings, task history, recent pages, and generated interfaces are stored locally. Timer updates, direct playback controls, window movement, and opacity changes do not themselves call the model.

**What about websites and Calendar?** Original webpages make their own network requests and use their own cookies. Ad filtering does not block all tracking. Calendar writes require macOS permission; closing a result card does not delete the event.

**What do optional connections allow?** Local connections are off by default. When enabled and paired with an external browser or agent, supported operations can read pages, query history, and control tasks. Connect only trusted clients and do not share pairing codes.

You can disable local connections, session restoration, or ad filtering in Settings. Closing a task releases its live page but does not erase all history or website data. There is currently no single control to erase all stored data.
