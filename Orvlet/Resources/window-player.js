// Keep the site's player, controls and media in their original document.
(() => {
  if (window.__orvletExitWindowPlayer || !['http:', 'https:', 'about:', 'blob:'].includes(location.protocol)) return;
  let current = null;
  let upstream = null;
  const message = 'orvlet-window-player';
  const policy = document.permissionsPolicy || document.featurePolicy;
  const permitted = () => !policy || policy.allowsFeature('fullscreen');
  const denied = () => new DOMException('Window playback is unavailable', 'NotAllowedError');

  function notify(active) {
    if (window !== top) return;
    document.documentElement.toggleAttribute('data-orvlet-player-active', active);
    document.dispatchEvent(new Event('orvlet-window-player-changed'));
  }
  function changed(element) {
    for (const name of ['fullscreenchange', 'webkitfullscreenchange']) {
      (element.isConnected ? element : document).dispatchEvent(new Event(name, { bubbles: true, composed: true }));
    }
    window.dispatchEvent(new Event('resize'));
  }
  function exit() {
    const session = current;
    if (!session) return;
    current = null;
    session.watch.disconnect();
    session.element.removeEventListener('toggle', checkPopover);
    session.restore();
    if (session.child) session.child.postMessage('exit');
    session.child?.close();
    if (upstream) { upstream.postMessage('exit'); upstream.close(); upstream = null; }
    notify(false);
    changed(session.element);
  }
  function checkPopover() {
    if (current?.usesPopover && !current.element.matches(':popover-open')) exit();
  }
  function fit(element) {
    const previous = element.getAttribute('popover');
    const usesPopover = element !== document.documentElement && element !== document.body;
    const alreadyOpen = element.matches(':popover-open');
    const root = element.getRootNode();
    const marker = 'data-orvlet-window-player';
    const hadMarker = element.hasAttribute(marker);
    // Some players size a single video in pixels and resize only the outer shell.
    const videos = element.querySelectorAll('video');
    const mediaRule = videos.length === 1 ? `[${marker}] video {
      width: 100vw !important; height: 100vh !important; max-width: 100vw !important;
      max-height: 100vh !important; object-fit: contain !important;
    }` : '';
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(`[${marker}] {
      position: fixed !important; inset: 0 !important; margin: 0 !important;
      padding: 0 !important; border: 0 !important; transform: none !important;
      width: 100vw !important; height: 100vh !important; max-width: none !important;
      max-height: none !important; box-sizing: border-box !important; background-color: black !important;
    } ${mediaRule}`);
    const restore = () => {
      root.adoptedStyleSheets = root.adoptedStyleSheets.filter(s => s !== sheet);
      if (!hadMarker) element.removeAttribute(marker);
      if (usesPopover && !alreadyOpen) {
        if (element.matches(':popover-open')) element.hidePopover();
        if (previous === null) element.removeAttribute('popover'); else element.setAttribute('popover', previous);
      }
    };
    try {
      if (usesPopover && !alreadyOpen) {
        element.setAttribute('popover', 'manual');
        element.showPopover();
      }
      element.toggleAttribute(marker, true);
      root.adoptedStyleSheets = [...root.adoptedStyleSheets, sheet];
    } catch (error) { restore(); throw error; }
    return { restore, usesPopover };
  }
  async function enter(element, child = null) {
    if (!element.isConnected || !permitted() || !navigator.userActivation.isActive) throw denied();
    if (current?.element === element) return;
    if (current) exit();
    let parentPort = null;
    if (window !== top) {
      const channel = new MessageChannel();
      parentPort = channel.port1;
      await new Promise((resolve, reject) => {
        const timeout = setTimeout(() => { parentPort.close(); reject(denied()); }, 1200);
        parentPort.onmessage = event => {
          clearTimeout(timeout);
          if (event.data === 'entered') resolve();
          else { parentPort.close(); reject(denied()); }
        };
        parent.postMessage(message, '*', [channel.port2]);
      });
      parentPort.onmessage = exit;
    }
    try {
      if (!element.isConnected) throw denied();
      const layout = fit(element);
      const watch = new MutationObserver(() => { if (!element.isConnected) exit(); });
      watch.observe(document, { subtree: true, childList: true });
      current = { element, child, watch, ...layout };
      upstream = parentPort;
      element.addEventListener('toggle', checkPopover);
      if (child) child.onmessage = exit;
      notify(true);
      changed(element);
    } catch (error) {
      if (parentPort) { parentPort.postMessage('exit'); parentPort.close(); }
      throw error;
    }
  }
  window.addEventListener('message', async event => {
    if (event.data !== message || event.ports.length !== 1) return;
    const port = event.ports[0];
    const frame = Array.from(document.querySelectorAll('iframe')).find(f => f.contentWindow === event.source);
    // A foreign player can expand only its own, explicitly delegated frame.
    const allow = frame?.getAttribute('allow')?.split(';').map(v => v.trim()).find(v => /^fullscreen(?:\s|$)/.test(v));
    const sameOrigin = event.origin !== 'null' && event.origin === location.origin;
    const origins = allow?.split(/\s+/).slice(1);
    const sourceOrigin = frame && new URL(frame.src || location.href, document.baseURI).origin;
    const delegated = origins ? ((!origins.length || origins.includes("'src'")) && event.origin === sourceOrigin
      || origins.includes(event.origin) || origins.includes('*') || (origins.includes("'self'") && sameOrigin))
      : sameOrigin || frame?.allowFullscreen;
    try {
      if (!frame || !delegated) throw denied();
      await enter(frame, port);
      port.postMessage('entered');
    } catch { port.postMessage('denied'); port.close(); }
  });
  const method = (target, name, fn) => Object.defineProperty(target, name, { configurable: true, writable: true, value: fn });
  for (const name of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
    method(Element.prototype, name, function () { return enter(this); });
  }
  const video = HTMLVideoElement.prototype;
  for (const name of ['webkitEnterFullscreen', 'webkitEnterFullScreen']) {
    if (name in video) method(video, name, function () { return enter(this); });
  }
  for (const name of ['webkitExitFullscreen', 'webkitExitFullScreen']) {
    if (name in video) method(video, name, function () { if (current?.element === this) exit(); });
  }
  if (video.webkitSetPresentationMode) {
    const setMode = video.webkitSetPresentationMode;
    method(video, 'webkitSetPresentationMode', function (mode) {
      if (mode === 'fullscreen') return enter(this);
      if (current?.element === this) exit();
      return setMode.call(this, mode);
    });
    const mode = Object.getOwnPropertyDescriptor(video, 'webkitPresentationMode');
    if (mode?.get && mode.configurable) Object.defineProperty(video, 'webkitPresentationMode', {
      ...mode, get() { return current?.element === this ? 'fullscreen' : mode.get.call(this); }
    });
  }
  for (const name of ['exitFullscreen', 'webkitExitFullscreen', 'webkitCancelFullScreen']) {
    method(document, name, async () => exit());
  }
  for (const name of ['fullscreenElement', 'webkitFullscreenElement', 'webkitCurrentFullScreenElement']) {
    Object.defineProperty(document, name, { configurable: true, get: () => current?.element || null });
  }
  for (const name of ['fullscreenEnabled', 'webkitFullscreenEnabled']) {
    Object.defineProperty(document, name, { configurable: true, get: permitted });
  }
  Object.defineProperty(document, 'webkitIsFullScreen', { configurable: true, get: () => !!current });
  method(window, '__orvletExitWindowPlayer', exit);
  window.addEventListener('pagehide', exit);
  window.addEventListener('keydown', event => {
    if (current && event.key === 'Escape') { event.preventDefault(); event.stopImmediatePropagation(); exit(); }
  }, true);
})();
