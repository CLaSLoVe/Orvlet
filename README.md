# Orvlet

A side-screen agent for macOS. It plays music, saves events, and helps with small calculations while you carry on with your work.

[简体中文](README.zh-CN.md) · macOS

![Music, calendar and calculation requests produce different interfaces](docs/assets/generative-ui.png)

## Why Orvlet?

Sometimes you just want some music on, or need to save a lecture notice to your calendar. Keeping a chat window open feels like a lot for that. We wanted a small assistant that sits beside your work, handles these everyday requests, and takes up very little attention.

Orvlet uses **generative UI** to build an interface for the task. A listening request gets playback controls; a bill calculation gets a form where you can change the amount and number of people. Use the controls directly, or ask for an adjustment. The illustration above shows a few examples; the actual layout depends on your request.

It can also turn relevant controls from a webpage into a small card. Music can keep playing while you set a timer or use another tool.

## Using it

Configure a model in **Settings → Models**, then press **⌥ Space** to ask for something. The input window closes when you submit; a task card appears when it's ready. A few things to try:

- “Play some quiet music while I work.”
- Paste a lecture notice with a time and location.
- “Split this 120 bill between three people. Let me edit the amount and people.”

Click a card to expand it, then press Esc or click outside to collapse. Pin it to keep it open, or drag it somewhere convenient. Cards fade when you're not using them.

Common timers work without a model. Natural-language tasks and UI generation use your configured model. Adding calendar events requires permission on first use.

<details>
<summary><strong>Controls & practical details</strong></summary>

- Click a card to expand it; click again, press Esc, or click outside to collapse. Pin details to keep them open. Drag the stack to move it.
- Right-click to close a task. Hiding a card keeps the task running; find it again in the task list. Closing a calendar card leaves the saved event intact.
- Choose a horizontal or vertical stack. Two tasks stay visible; the rest go into the task list. Idle opacity defaults to 55%, adjustable in **Settings → General → Inactive opacity**.
- Model and website response times vary. Up to three webpage tasks can stay live. Ad filtering is enabled, though some ads may still appear.
- Generated calculations use time-limited JavaScript with no direct file, shell, or network access. Task interfaces and inputs stay on your Mac.
- Calendar creation checks for duplicates and reads the event back before reporting success. Without an explicit time zone, it uses Hong Kong time and prefers calendars named 工作 or 安排.

</details>

---

[Privacy](PRIVACY.md) · [Third-party notices](THIRD_PARTY_NOTICES.md)
