# Orvlet

A quiet helper at the edge of your Mac desktop.

Most tools compete for your attention. Orvlet helps you keep it for the work in front of you.

Small cards keep side tasks running in the background. Come back when you want to do one of three things:

- **Delegate** — “Set a timer for 25 minutes.” “Split HK$360 between four people.”
- **Adjust** — Pause the music, change the bill total, or add another person right on the card.
- **Check** — Glance over to see what’s playing or how much time is left.

[Download for Apple silicon](https://github.com/CLaSLoVe/Orvlet/releases/latest/download/Orvlet-macOS-arm64.zip) · [Watch the 78-second demo](https://claslove.github.io/Orvlet/) · [简体中文](README.zh-CN.md)

![Music and timer cards beside a shared bill with an editable headcount](docs/assets/generative-ui.png)

## What you can do

- **Timers** — Set a timer and glance over to see how much time is left.
- **Music** — Ask for music, then pause, skip, or check the current track.
- **Shared bills** — Ask Orvlet to split a bill, then edit the numbers on the card.
- **Pick up where you left off** — Orvlet remembers earlier decisions in a task and which parts of a website have asked you to sign in.

## First-time setup

Use an Apple silicon Mac running macOS 14 or later. Unzip the download and drag **Orvlet** to **Applications**.

1. **Configure a model before you start.** Open Orvlet, go to **Settings → Models**, select **GPT**, and enter your OpenAI API key. We tested with `gpt-6.2-sol` as the main model.
2. Select your model and click **Save changes**. [Setup for other models](docs/model-connections.md)
3. Press **⌥ Space** and try “Set a timer for 25 minutes” or “Check Apple’s stock price.”

## Memory and privacy

Orvlet saves task history and website access notes on your Mac. To summarize a long conversation, it may send older, non-sensitive excerpts to the model you configured. View or delete saved memories in **Settings → Data → Review memory**.

This release is locally signed and has not been notarized by Apple. [First-open help](https://support.apple.com/en-us/102445)

[Privacy](PRIVACY.md) · [Build from source](CONTRIBUTING.md)
