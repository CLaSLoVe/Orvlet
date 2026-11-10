(() => {
  if (window.__orvlet) return;
  const refs = new Map();
  let revision = 0;
  let interaction = '';
  let readingBindings = [];
  document.addEventListener('pointerdown', e => { if (e.isTrusted) interaction = 'pointer:' + (label(e.target) || e.target.tagName).slice(0,70); }, true);
  document.addEventListener('keydown', e => { if(e.isTrusted) interaction = 'keyboard:' + (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' ? 'typing' : e.key); }, true);
  const visible = e => { const r = e.getBoundingClientRect(); const s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
  const label = e => (e.getAttribute('aria-label') || e.getAttribute('aria-labelledby')?.split(/\s+/).map(id=>document.getElementById(id)?.textContent||'').join(' ') || e.getAttribute('title') || e.labels?.[0]?.innerText || e.getAttribute('placeholder') || e.innerText || e.getAttribute('alt') || e.querySelector('img')?.alt || '').trim().replace(/\s+/g,' ').slice(0, 140);
  const elements = () => {
    const all = [];
    const walk = root => {
      for (const e of root.querySelectorAll('*')) {
        if (e.shadowRoot) walk(e.shadowRoot);
        if (e.matches('button,a[href],input,textarea,select,[role="button"],[role="link"],[role="textbox"],[role="slider"],[role="tab"],[contenteditable="true"],audio,video,canvas') && visible(e)) all.push(e);
      }
    };
    walk(document); return all;
  };
  const media = () => [...document.querySelectorAll('video,audio')].sort((a,b) => {
    const score = m => (visible(m) ? 32 : 0) + (m.controls ? 16 : 0) + (m.currentSrc ? 4 : 0) + (!m.paused && !m.ended ? 8 : 0) + (!m.muted && m.volume > 0 ? 16 : 0);
    return score(b) - score(a);
  })[0];
  const dataControl = e => e.matches('input:not([type]),input[type="text"],input[type="number"],input[type="search"],input[type="date"],input[type="time"],select,[role="combobox"],button[aria-haspopup="listbox"]');
  const readable = e => e && visible(e) && !e.closest('script,style,[contenteditable="true"],[aria-hidden="true"],input[type="password"],input[type="hidden"]') && (!e.matches('input,textarea') || dataControl(e));
  const readText = e => {
    if(!readable(e))return '';
    const value=e.matches('select') ? e.selectedOptions?.[0]?.textContent : e.matches('input') ? e.value : e.innerText || e.textContent;
    return (value || '').trim().replace(/\s+/g,' ').slice(0,240);
  };
  const selectorFor = e => {
    if(e.id && document.querySelectorAll('#'+CSS.escape(e.id)).length===1)return '#'+CSS.escape(e.id);
    const parts=[];let n=e;
    while(n && n!==document.body && parts.length<8){let i=1,p=n;while((p=p.previousElementSibling))if(p.tagName===n.tagName)i++;parts.unshift(n.tagName.toLowerCase()+':nth-of-type('+i+')');n=n.parentElement;}
    return (n===document.body?'body > ':'')+parts.join(' > ');
  };
  const readings = () => Object.fromEntries(readingBindings.map(b=>{let nodes;try{nodes=document.querySelectorAll(b.selector)}catch{return [b.key,'—']};return [b.key,nodes.length===1 ? readText(nodes[0]) || '—' : '—']}));
  const youtubePlayer = () => /(^|\.)youtube\.com$/.test(location.hostname) ? document.getElementById('movie_player') : null;
  const state = () => {
    const m = media();
    const player = youtubePlayer();
    const live = player?.getVideoData?.()?.isLive === true || m?.duration === Infinity;
    const ended = m?.ended === true || player?.getPlayerState?.() === 0;
    const adPlaying = window.__orvletAds?.isAd?.() === true;
    return {documentReady:document.readyState, adPlaying, title: navigator.mediaSession?.metadata?.title || document.title, url: location.href, readings:readings(), mediaPrimary:!!m && ((visible(m) && (m.controls || m.tagName==='VIDEO')) || !!navigator.mediaSession?.metadata?.title),
      playing: !!m && !m.paused && !ended && m.readyState >= 2, audible: !!m && !m.paused && !ended && !m.muted && m.volume > 0 && m.readyState >= 2, looping: m?.loop ?? false, muted: player?.isMuted?.() ?? m?.muted ?? false, readyState: m?.readyState ?? 0, mediaError: m?.error?.message || '', hasMedia: !!m && (!!m.currentSrc || !!m.srcObject || m.readyState >= 1), mediaType: m?.tagName.toLowerCase(),
      width: m?.videoWidth || 0, height: m?.videoHeight || 0,
      interaction, hasCanvas: !!document.querySelector('canvas'), volume: player?.getVolume ? player.getVolume()/100 : m?.volume ?? 1,
      artist: navigator.mediaSession?.metadata?.artist || '',
      ended, live, seekable: !live && !!m && Number.isFinite(m.duration) && m.duration > 0 && (m.seekable.length > 0 || !!player?.seekTo),
      currentTime: m?.currentTime || 0, duration: Number.isFinite(m?.duration) ? m.duration : 0};
  };
  window.__orvlet = {
    state,
    musicCandidates() {
      if (!['www.youtube.com','youtube.com','m.youtube.com'].includes(location.hostname)) return [];
      const seen = new Set(), results = [];
      for (const row of document.querySelectorAll('ytd-video-renderer,ytd-compact-video-renderer,ytm-video-with-context-renderer')) {
        if (row.closest('ytd-ad-slot-renderer,ytd-promoted-sparkles-web-renderer')) continue;
        const link = row.querySelector('a#video-title,a[href*="/watch?v="]');
        if (!link) continue;
        const id = new URL(link.href, location.href).searchParams.get('v');
        const title = (link.getAttribute('title') || row.querySelector('#video-title,h3')?.textContent || link.textContent || '').trim();
        if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id) || !title || seen.has(id)) continue;
        seen.add(id);
        const clean = text => (text || '').trim().replace(/\s+/g,' ');
        results.push({id,title:clean(title).slice(0,220),subtitle:clean(row.querySelector('ytd-channel-name a,#channel-name a,.ytm-badge-and-byline-item-byline')?.textContent).slice(0,100),durationLabel:clean(row.querySelector('ytd-thumbnail-overlay-time-status-renderer #text,.badge-shape-wiz__text')?.textContent).slice(0,30),verifiedArtist:!!row.querySelector('.badge-style-type-verified-artist,[aria-label="Official Artist Channel"],[aria-label="音乐人官方频道"],[aria-label="音樂人官方頻道"]'),isLive:!!row.querySelector('.badge-style-type-live-now,ytd-thumbnail-overlay-time-status-renderer[overlay-style="LIVE"]')});
        if(results.length===12)break;
      }
      return results;
    },
    bindReadings(bindings) {
      if(!Array.isArray(bindings)||bindings.length>8)throw Error('Invalid reading bindings');
      readingBindings=bindings.filter(b=>typeof b.key==='string'&&typeof b.selector==='string'&&b.selector.length<400);
      return state();
    },
    observe() {
      revision++;
      if(refs.size > 1400) for(const key of [...refs.keys()].slice(0,1000)) refs.delete(key);
      const candidates = elements();
      // Prefer the current viewport while retaining a bounded set of below-fold targets.
      const onscreen = e => {const r=e.getBoundingClientRect();return r.bottom>0 && r.top<innerHeight && r.right>0 && r.left<innerWidth;};
      const controls = candidates.filter(e => e.matches('button,input,textarea,select,[role="button"],[role="textbox"],[role="slider"]') || e.closest('nav,[role="navigation"]'));
      const ranked = [...new Set([...controls.slice(0,24), ...candidates.filter(onscreen).slice(0,40), ...candidates.slice(-16), ...candidates])];
      const items = ranked.slice(0, 80).map((e,i) => {
        const id = `${revision}:${i}`; refs.set(id,e);
        const r = e.getBoundingClientRect();
        return {id, role:e.getAttribute('role') || e.tagName.toLowerCase(), label:label(e),
          editable:e.type !== 'password' && (e.matches('input:not([type=button]):not([type=submit]):not([type=checkbox]):not([type=radio]),textarea') || e.isContentEditable), value:e.type === 'password' ? undefined : e.value?.slice?.(0,120), href:e.getAttribute('href'),
          disabled:!!e.disabled, x:Math.round(r.x), y:Math.round(r.y), width:Math.round(r.width), height:Math.round(r.height)};
      });
      const candidatesText=[...document.querySelectorAll('time,output,input,select,[role="combobox"],button[aria-haspopup="listbox"],[role="heading"],[role="timer"],[role="status"],h1,h2,h3,[id],main p,main strong,main span')].filter(e=>readable(e)&&readText(e)&&readText(e).length<220 && (!e.matches('a,button') || dataControl(e)) && !e.querySelector('input[type="password"]'));
      const prominent=e=>parseFloat(getComputedStyle(e).fontSize)||0;
      const readables=[...new Set(candidatesText)].sort((a,b)=>prominent(b)-prominent(a)).slice(0,70).map(e=>{
        // Search suggestions, related links and navigation are not the selected result.
        const navigation=!!e.closest('a,nav,aside,[role="navigation"],[role="listbox"],[role="menu"]') || (!!e.closest('button') && !dataControl(e));
        const selected=dataControl(e) || e.matches('[aria-selected="true"],[aria-current="true"],[aria-current="page"],option:checked');
        const primary=e.matches('h1,[role="heading"][aria-level="1"],output,time,[role="timer"],[role="status"]');
        const scope=e.closest('form,section,article,main,[role="main"]') || document.body;
        return {selector:selectorFor(e),text:readText(e),role:e.getAttribute('role')||e.tagName.toLowerCase(),
          evidenceRole:navigation?'navigation':selected?'selected':primary?'primary':'supporting',
          scopeSelector:scope===document.body?'body':selectorFor(scope)};
      });
      return {...state(), readables, viewport:{width:innerWidth,height:innerHeight}, elements:items,
        text:(document.body?.innerText || '').slice(0,2800) + ((document.body?.innerText || '').length > 2800 ? '\n…\n' + document.body.innerText.slice(-700) : ''), frames: [...document.querySelectorAll('iframe')].map(f=>({title:f.title,src:f.src})).slice(0,8)};
    },
    async act(a) {
      if (a.action === 'observe') return this.observe();
      if (['back','forward','reload'].includes(a.action)) {
        setTimeout(() => a.action === 'reload' ? location.reload() : history.go(a.action === 'back' ? -1 : 1), 0);
        return {ok:true, navigating:true};
      }
      if (a.action === 'media') {
        if (!['play','pause','toggle','seek','volume','mute','unmute','toggleMute','next','previous','loop','unloop'].includes(a.operation)) throw Error('Unsupported media operation.');
        const m = media();
        const player = youtubePlayer();
        if (['next','previous'].includes(a.operation)) {
          const pattern = a.operation === 'next' ? /next|下一|下首|次へ/i : /previous|上一|上首|前へ/i;
          const target = elements().find(e => pattern.test(label(e)) && !e.disabled);
          if (!target) throw Error('Track control not found. Inspect the page again.');
          target.click(); return {ok:true};
        }
        if (!m) throw Error('No controllable media on this page.');
        if (a.operation === 'loop' || a.operation === 'unloop') {
          if (a.operation === 'loop' && (window.__orvletAds?.isAd?.() === true || player?.getVideoData?.()?.isLive === true || !Number.isFinite(m.duration) || m.duration <= 0)) throw Error('Looping is unavailable for this player or live stream. Playback was left unchanged.');
          m.loop = a.operation === 'loop';
          return state();
        }
        if (a.operation === 'pause' || (a.operation === 'toggle' && !m.paused && !m.ended && player?.getPlayerState?.() !== 0)) { player?.pauseVideo?.(); m.pause(); }
        else if (['mute','unmute','toggleMute'].includes(a.operation)) {
          const muted = a.operation === 'mute' || (a.operation === 'toggleMute' && !(player?.isMuted?.() ?? m.muted));
          if (player?.mute && player?.unMute) { if(muted)player.mute();else player.unMute(); }
          m.muted = muted;
        }
        else if (a.operation === 'seek') {
          if (!Number.isFinite(a.value) || !Number.isFinite(m.duration) || m.duration<=0 || window.__orvletAds?.isAd?.()===true || player?.getVideoData?.()?.isLive===true) throw Error('Seeking is unavailable for this player.');
          if (player?.seekTo) player.seekTo(Math.max(0,Math.min(m.duration,a.value)),true);
          else {
            if (!m.seekable.length) throw Error('Seeking is unavailable for this player.');
            m.currentTime = Math.max(m.seekable.start(0),Math.min(m.seekable.end(m.seekable.length-1),a.value));
          }
        }
        else if (a.operation === 'volume') {
          if(!Number.isFinite(a.value))throw Error('Invalid volume.');
          const volume = Math.max(0,Math.min(1,a.value));
          if (player?.setVolume) player.setVolume(volume*100); else m.volume = volume;
        }
        else {
          if (a.operation === 'play') { player?.unMute?.(); m.muted = false; }
          // Replay a completed track from zero; ordinary pause/resume keeps its position.
          const ended = m.ended || player?.getPlayerState?.() === 0;
          if (ended && Number.isFinite(m.duration) && player?.getVideoData?.()?.isLive !== true) {
            if (player?.seekTo) player.seekTo(0, true);
            else m.currentTime = 0;
          }
          if (player?.playVideo) player.playVideo();
          await Promise.race([m.play(), new Promise((_,reject)=>setTimeout(()=>reject(Error('Playback has not started. Check the source and try again.')),6000))]);
        }
        return state();
      }
      if (a.action === 'pip') {
        const m=media(); if (!m || m.tagName !== 'VIDEO') throw Error('No video on this page.');
        if (m.webkitSetPresentationMode) m.webkitSetPresentationMode('picture-in-picture');
        else await m.requestPictureInPicture(); return {ok:true};
      }
      if (a.action === 'scroll') { window.scrollBy({top:Number(a.y)||innerHeight*0.7,left:Number(a.x)||0,behavior:'smooth'}); return {ok:true}; }
      let e = refs.get(a.id);
      if (!e && a.name) {
        const matches = elements().filter(el => label(el) === a.name && (el.getAttribute('role') || el.tagName.toLowerCase()) === a.role);
        if(matches.length !== 1) throw Error('Binding changed. Inspect the page again.');
        e = matches[0];
      }
      const protectPlayback = target => {
        const m = media();
        if (!a.preservePlayback || !m || m.paused || m.ended || !target) return;
        const control = target.closest?.('button,[role="button"],audio,video') || target;
        const name = label(control);
        if (control === m || /^(play|pause|play\s*[/／]\s*pause|播放|暂停|播放\s*[/／]\s*暂停)(?:$|\s*[（(])/i.test(name)) {
          throw Error('Media is already playing. Use media operation play to ensure playback; do not click its toggle.');
        }
      };
      if (a.action === 'key') {
        const target = e || document.activeElement || document.body;
        const key = String(a.key || '');
        if (a.preservePlayback && [' ','k','K','MediaPlayPause'].includes(key) && !target.matches?.('input,textarea,[contenteditable="true"]')) protectPlayback(media());
        if(!key || key.length > 30) throw Error('Invalid key.');
        const code = key === ' ' ? 'Space' : key.length===1 ? 'Key'+key.toUpperCase() : key;
        const send = type => target.dispatchEvent(new KeyboardEvent(type,{key,code,bubbles:true,cancelable:true,composed:true}));
        if(a.operation === 'up') send('keyup');
        else { send('keydown'); if(a.operation !== 'down') { await new Promise(r=>setTimeout(r,Math.min(1000,Math.max(30,Number(a.value)||60))));send('keyup'); } }
        return {ok:true,synthetic:true};
      }
      if (a.action === 'pointer') {
        const target = e || document.elementFromPoint(Number(a.x),Number(a.y));
        if(!target) throw Error('Pointer target not found.');
        if (a.operation !== 'move') protectPlayback(target);
        const rect=target.getBoundingClientRect();
        const x=Number.isFinite(a.x)?a.x:rect.x+rect.width/2,y=Number.isFinite(a.y)?a.y:rect.y+rect.height/2;
        const send=(type,buttons)=>{target.dispatchEvent(new PointerEvent('pointer'+type,{clientX:x,clientY:y,pointerId:1,pointerType:'mouse',buttons,bubbles:true,composed:true}));target.dispatchEvent(new MouseEvent('mouse'+type,{clientX:x,clientY:y,buttons,bubbles:true,composed:true}));};
        if(a.operation==='move')send('move',0);else if(a.operation==='down')send('down',1);else if(a.operation==='up')send('up',0);else{send('down',1);send('up',0);target.click();}
        return {ok:true,synthetic:true};
      }
      if (a.action === 'click' && !e && Number.isFinite(a.x) && Number.isFinite(a.y)) e = document.elementFromPoint(a.x,a.y);
      if (!e || !e.isConnected) throw Error('Page changed. Inspect before acting.');
      if (e.disabled) throw Error('This control is disabled.');
      if (a.action === 'click') protectPlayback(e);
      e.scrollIntoView({block:'nearest'}); e.focus();
      if (a.action === 'click') e.click();
      else if (a.action === 'type') {
        if (!e.matches('input,textarea') && !e.isContentEditable) throw Error('This element is not a text field.');
        if (e.type === 'password') throw Error('Enter the password yourself on the page.');
        if (e.isContentEditable) e.textContent = a.text || '';
        else {
          const proto = e.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(proto,'value')?.set;
          if (!setter) throw Error('This element is not a text field.');
          setter.call(e,a.text || '');
        }
        e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true}));
      } else if (a.action === 'select') { e.value=a.text; e.dispatchEvent(new Event('change',{bubbles:true})); }
      else if (a.action === 'submit') { if (e.form) e.form.requestSubmit(); else throw Error('No form to submit. Use the observed submit button.'); }
      else throw Error('Unsupported action.');
      return {ok:true};
    }
  };
  let last='';
  document.addEventListener('ended', () => window.webkit?.messageHandlers?.orvlet?.postMessage(state()), true);
  setInterval(() => {
    const s=state(), signature=JSON.stringify(s);
    if (signature!==last) { last=signature; window.webkit?.messageHandlers?.orvlet?.postMessage(s); }
  },1000);
})();
