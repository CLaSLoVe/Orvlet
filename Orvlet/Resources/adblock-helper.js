(() => {
  if (window.__orvletAds) return;
  let enabled = __ORVLET_ADBLOCK_ENABLED__;
  const youtube = /(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname);
  const adPlayer = '.html5-video-player.ad-showing, .html5-video-player.ad-interrupting';
  const skipControl = [
    '.ytp-skip-ad-button', '.ytp-skip-ad-button-modern', '.ytp-ad-skip-button',
    '.ytp-ad-skip-button-modern', '.ytp-ad-skip-button-slot button', '.ytp-ad-skip-ad-slot button',
  ].join(',');
  const lastClick = new WeakMap();
  let queued = false, observer = null, timer = null;
  const isAd = () => youtube && !!document.querySelector(adPlayer);

  function canSkip(button) {
    if (!button.matches('button,[role="button"]') || button.closest('a,[hidden],[inert],[aria-hidden="true"],[aria-disabled="true"]') || button.disabled) return false;
    const bounds = button.getBoundingClientRect();
    return bounds.width > 0 && bounds.height > 0 && getComputedStyle(button).visibility === 'visible';
  }
  function inspect() {
    queued = false;
    if (!enabled) return;
    for (const player of document.querySelectorAll(adPlayer)) {
      // A paused content video can stay mounted alongside the playing ad.
      if (![...player.querySelectorAll('video')].some(video => !video.paused && !video.ended)) continue;
      const button = [...player.querySelectorAll(skipControl)].find(canSkip);
      if (!button || Date.now() - (lastClick.get(button) ?? 0) < 1500) continue;
      lastClick.set(button, Date.now());
      button.click();
    }
  }
  function schedule() {
    if (queued || !enabled) return;
    queued = true;
    setTimeout(inspect, 100);
  }
  function observe() {
    observer?.disconnect();
    clearInterval(timer);
    if (!enabled || !youtube || !document.documentElement) return;
    observer = new MutationObserver(schedule);
    observer.observe(document.documentElement, {subtree: true, childList: true, attributes: true,
      attributeFilter: ['class', 'style', 'disabled', 'hidden', 'aria-disabled', 'aria-hidden']});
    timer = setInterval(schedule, 1000);
    schedule();
  }
  function setEnabled(value) {
    enabled = !!value;
    observe();
    for (let i = 0; i < frames.length; i++) frames[i].postMessage({orvletAdBlocking: enabled}, '*');
  }
  window.addEventListener('message', event => {
    if (window !== parent && event.source === parent && typeof event.data?.orvletAdBlocking === 'boolean') {
      setEnabled(event.data.orvletAdBlocking);
    }
  });
  window.__orvletAds = {isAd, setEnabled};
  if (document.documentElement) observe();
  else document.addEventListener('DOMContentLoaded', observe, {once: true});
})();
