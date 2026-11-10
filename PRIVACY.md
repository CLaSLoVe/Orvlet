# 隐私说明 · Privacy

## 中文

**模型会收到什么？** 处理自然语言请求或生成界面时，Orvlet 会将相关请求、对话、任务状态、生成的代码和所需的网页内容发送给你在设置中选择的模型服务。内容可能包括网页标题、地址、文字和操作按钮；开启视觉输入并使用截图时，也可能包含网页截图。请留意所使用模型服务的隐私政策。

**什么留在本机？** 模型密钥保存在应用沙盒的 Application Support/Orvlet/Private/credentials-v1.json，只有当前用户可读写（目录 0700、文件 0600），正常运行不访问 Keychain。这是本地明文存储，不是加密保险库；密钥不写入源码或安装包。设置、每个任务最近 500 条对话及其归属、任务记录、最近访问的网页、生成的界面及其代码和输入状态保存在本机。计算按钮在独立的 JavaScript 进程中运行，不接触模型密钥，也不直接访问文件、终端或网络；选择交由 Agent 继续处理的操作时，相关状态和输入会发送给模型。持续时钟、经过时间、周期计算和计时更新、直接播放控制、窗口移动和透明度变化本身不调用模型。

**按习惯排序会发送什么？** 打开、操作、隐藏及拖动的衰减统计保存在本机；手动排序优先。已配置 Jev 时，后台排序可向 api.typesafe.ai 发送匿名任务类别、播放／计时／完成状态和汇总习惯分数。排序不发送任务标题、网页内容、网址或聊天记录。没有可用密钥或网络时使用本地排序，直接控制无需等待模型。

**网页和日历呢？** 原网页仍会正常联网并使用自己的 Cookie。广告过滤不能阻止所有追踪。日程只在获得系统授权后写入 Apple 日历，关闭结果卡片不会删除事件。

**故障诊断保存什么？** 本机保留最近 150 条请求阶段、耗时、错误类别与任务标识，可在设置中复制。它们不包含对话内容、网页地址、生成代码、输入值或密钥。

**可选连接有什么影响？** 本机连接默认关闭。开启并配对外部浏览器或 agent 后，对方可以通过支持的操作读取网页、查询历史和控制任务。只连接你信任的客户端，不要分享配对码。

你可以在设置中分别清除对话和最近页面。旧版本未保存的对话无法恢复。你可以在设置中关闭本机连接、会话恢复或广告过滤。关闭任务会释放其运行中的网页，但不会自动清除所有历史和网站数据。目前尚无一键清除全部数据的入口。

## English

**What reaches the model?** Natural-language assistance and interface generation send relevant requests, conversation, task state, generated code, and necessary page content to the model provider you choose in Settings. This may include page titles, URLs, text, and controls. With visual input enabled, requested webpage screenshots may also be sent. Review your provider's privacy policy.

**What stays on this Mac?** API keys are stored in the app container’s Application Support/Orvlet/Private/credentials-v1.json with owner-only permissions (directory 0700, file 0600). Normal operation does not access Keychain. This is local plaintext storage, not an encrypted vault; keys are never written to source files or the app bundle. Settings, the latest 500 conversation messages per task and their attribution, task history, recent pages, generated interfaces, their code, and input state are stored locally. Calculation buttons run in a separate JavaScript process without access to model keys, files, a shell, or networking. Actions that ask the agent to continue send the relevant state and inputs to the model. Continuing clocks, elapsed time, scheduled local calculations, timer updates, direct playback controls, window movement, and opacity changes do not themselves call the model.

**What does habit-based ordering send?** Decaying aggregates of opens, controls, hides, and reorders stay on this Mac; manual ordering takes precedence. With Jev configured, background ordering may send anonymous task categories, playback/timer/completion state, and aggregate habit scores to api.typesafe.ai. Ranking sends no task titles, page content, URLs, or conversations. Without an available key or network it uses local ordering; direct controls never wait for a model.

**What about websites and Calendar?** Original webpages make their own network requests and use their own cookies. Ad filtering does not block all tracking. Calendar writes require macOS permission; closing a result card does not delete the event.

**What do diagnostics store?** The latest 150 stage, timing, error-category and task-identity events stay locally and can be copied in Settings. They contain no conversation text, page URLs, generated code, input values or keys.

**What do optional connections allow?** Local connections are off by default. When enabled and paired with an external browser or agent, supported operations can read pages, query history, and control tasks. Connect only trusted clients and do not share pairing codes.

Settings has separate actions to clear conversations and recent pages. Conversation text not saved by older versions cannot be recovered. You can disable local connections, session restoration, or ad filtering in Settings. Closing a task releases its live page but does not erase all history or website data. There is currently no single control to erase all stored data.

**Jev 请求分流（可选）**：启用 Jev 后，短请求可用于判断任务路由、思考预算、已有任务控制和已保存卡片复用。发送当前请求、匿名候选类别／播放状态，以及通过筛选的卡片用途、输入／输出标签和有限参数选项；不发送保存的结果或执行代码；不发送候选任务标题、网址、持久 ID 或聊天历史。明显包含凭据、个人标识或敏感内容的请求，以及长文本，会跳过 Jev。此本地筛选不是通用敏感信息检测器。关闭、超时或置信度不足时使用主模型原有流程；排序仍按原有匿名汇总规则处理。

**Optional Jev request triage:** When enabled, short requests may be sent for routing, reasoning-budget advice, existing-task controls, and saved-card reuse. Payloads contain the current request, anonymous candidate categories/playback flags, and screened saved-method purposes, input/output labels and bounded parameter options. They exclude stored results, execution code, task titles, URLs, persistent IDs and conversation history. Obvious credentials, identifiers, sensitive requests and long text bypass this optional service; the local screening is not a general sensitive-data detector. Disabled, timed-out or uncertain triage uses the existing main-model flow. Background ordering retains its separate anonymous aggregate payload.

## Public data APIs

Structured queries can read public HTTPS JSON APIs directly, without opening a browser. Requests carry the query URL, not model credentials, browser cookies or custom authorization headers. The selected source URL, field mappings, calculation inputs/code and extracted results are saved with the task so Refresh can fetch and recompute without another model call. Cards distinguish the source publication date from the retrieval time; an unavailable refresh preserves and labels the previous result. No API key is bundled for these public data sources. API responses are treated as untrusted data.
