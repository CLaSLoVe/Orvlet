(() => {
  if (window.__orvletAds) return;
  let enabled = __ORVLET_ADBLOCK_ENABLED__;
  const youtube = /(^|\.)youtube(-nocookie)?\.com$/.test(location.hostname);
  let queued = false, observer = null, timer = null, lastButton = null, lastClick = 0;
  const isAd = () => youtube && !!document.querySelector('.html5-video-player.ad-showing, .html5-video-player.ad-interrupting');
  function inspect() {
    queued = false;
    if (!enabled || !isAd()) return;
    const video = document.querySelector('.html5-video-player.ad-showing video, .html5-video-player.ad-interrupting video');
    if (!video || video.paused) return;
    // Only use YouTube's actual skip control. Never click ad destinations, seek the
    // content video, change mute/volume, or press play behind a user's pause.
    const button = [...document.querySelectorAll('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern')]
      .find(b => { const r=b.getBoundingClientRect(); return !b.disabled && r.width>0 && r.height>0 && getComputedStyle(b).visibility!=='hidden'; });
    if (!button || (button===lastButton && Date.now()-lastClick<1500)) return;
    lastButton = button; lastClick = Date.now(); button.click();
  }
  function schedule() {
    if (queued || !enabled) return;
    queued = true; setTimeout(inspect,100);
  }
  function setEnabled(value) {
    enabled = !!value;
    observer?.disconnect(); observer = null;
    if (timer) clearInterval(timer); timer = null;
    if (!enabled || !youtube || !document.documentElement) return;
    observer = new MutationObserver(schedule);
    observer.observe(document.documentElement,{subtree:true,childList:true,attributes:true,attributeFilter:['class','style','disabled']});
    timer = setInterval(schedule,1000);
    schedule();
  }
  window.__orvletAds = {isAd,setEnabled};
  if (document.documentElement) setEnabled(enabled);
  else document.addEventListener('DOMContentLoaded',()=>setEnabled(enabled),{once:true});
})();
