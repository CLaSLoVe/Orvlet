const input=document.getElementById('token'),status=document.getElementById('status');
chrome.storage.local.get(['token','tabId']).then(s=>{input.value=s.token||'';status.textContent=s.tabId?'已选择标签页':'在软件设置 → 连接中复制配对码';});
document.getElementById('connect').onclick=async()=>{
 try {
  // Permission is granted by the human in the extension popup, never by page content.
  const granted=await chrome.permissions.request({origins:['https://*/*','http://*/*']});
  if(!granted){status.textContent='需要网页访问权限才能连接';return;}
  const [tab]=await chrome.tabs.query({active:true,currentWindow:true});
  if(!/^https?:/.test(tab.url||''))throw Error('请先打开一个普通网页');
  const token=input.value.trim();if(!token)throw Error('请输入配对码');
  await chrome.storage.local.set({token,tabId:tab.id});
  await chrome.runtime.sendMessage({type:'start'});status.textContent='已连接。软件设置中选择使用已连接浏览器。';
 }catch(e){status.textContent=e.message;}
};
document.getElementById('stop').onclick=async()=>{await chrome.runtime.sendMessage({type:'stop'});status.textContent='已断开';};
