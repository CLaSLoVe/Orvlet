# Optional integrations

These integrations are experimental developer surfaces. The built-in browser is the default, and **Allow local connections** is off by default. Neither integration requires a bundled provider key.

## Loopback bridge

Enable **Settings → Advanced → Allow local connections**. The app listens on `127.0.0.1:19243`, generates a per-run pairing token, and writes a discovery file in its application-support directory. The token grants access to supported page/history operations; do not commit it or share it with an untrusted client. Disabling connections stops the listener and removes the discovery file.

## Chrome / Edge extension

1. In the browser's extension manager, enable developer mode and load `integrations/browser/` as an unpacked extension.
2. Open the desired HTTP(S) tab and the extension popup.
3. Copy the pairing code from Orvlet's Advanced settings, paste it into the popup, and connect the selected tab.
4. Select the connected browser in Orvlet's Advanced settings. Disconnect from the popup when finished.

The extension uses `activeTab`, scripting, local storage, and alarms. Its popup currently requests optional access to **all HTTP(S) sites** so the chosen tab can navigate across sites; actual polling targets the selected tab ID. This is broader permission than a single-origin grant. Do not describe the extension as a per-site permission model. The token is stored in browser extension local storage.

Source content remains in the external browser; external video mirroring is not implemented. Orvlet's built-in ad filtering does not apply to external tabs. The extension is a connection bridge, not an ad-blocking extension.

## MCP adapter

`integrations/mcp/server.py` is a newline-delimited stdio MCP adapter using only the Python standard library. Configure your MCP client with your own checkout path:

```json
{
  "mcpServers": {
    "orvlet": {
      "command": "python3",
      "args": ["/path/to/Orvlet/integrations/mcp/server.py"]
    }
  }
}
```

The adapter discovers the local bridge file; no token belongs in this configuration. Start Orvlet and enable local connections first. Supported tools include state/observation, page actions, screenshots, generated UI proposals, outcome verification, visibility, history, and session restoration. Read [the integration instructions](mcp/SKILL.md) before allowing an agent to operate it.

`compose_ui` proposes a pending interface; `finish` verifies the requested outcome and installs it. Calling compose alone does not make a verified card appear. Provider-backed app orchestration is distinct from this transport: the adapter does not choose or call a model itself.
