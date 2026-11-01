let running=false,loopTimer;
const base='http://127.0.0.1:19243';
async function api(path,body,token){const r=await fetch(base+path,{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+token},body:JSON.stringify(body),signal:AbortSignal.timeout(5000)});if(!r.ok)throw Error('请重新配对');return r.json();}
async function execute(tabId,input){
 if(input.action==='navigate'){const u=new URL(input.url);if(!['http:','https:'].includes(u.protocol))throw Error('仅支持网页地址');await chrome.tabs.update(tabId,{url:u.href});return {ok:true,loading:true};}
 if(input.action==='screenshot'){
  const tab=await chrome.tabs.get(tabId),[active]=await chrome.tabs.query({active:true,windowId:tab.windowId});
  if(active?.id!==tabId)throw Error('请将连接的标签页切到前台再读取画面');
  const data=await chrome.tabs.captureVisibleTab(tab.windowId,{format:'jpeg',quality:70});return {image:data.split(',')[1]};
 }
 await chrome.scripting.executeScript({target:{tabId},world:'ISOLATED',files:['browser.js']});
 const results=await chrome.scripting.executeScript({target:{tabId},world:'ISOLATED',func:async a=>{
  if(a.action==='state')return window.__orvlet.state();
  return await window.__orvlet.act(a);
 },args:[input]});
 return results[0]?.result||{};
}
async function tick(){
 if(!running)return;
 try{
  const {token,tabId}=await chrome.storage.local.get(['token','tabId']);
  if(!token||!tabId){running=false;return;}
  const response=await api('/browser/poll',{},token);
  for(const command of response.commands||[]){
   try{const result=await execute(tabId,command.input);await api('/browser/result',{id:command.id,result},token);}
   catch(e){await api('/browser/result',{id:command.id,error:e.message},token);}
  }
  try{await api('/browser/state',await execute(tabId,{action:'state'}),token);}catch{}
 }catch{}
 if(running)loopTimer=setTimeout(tick,1000);
}
function start(){if(running)return;running=true;tick();chrome.alarms.create('orvlet',{periodInMinutes:.5});}
chrome.runtime.onMessage.addListener((message,sender,reply)=>{
 if(sender.id!==chrome.runtime.id)return;
 if(message.type==='start'){start();reply({ok:true});}
 if(message.type==='stop'){running=false;clearTimeout(loopTimer);chrome.storage.local.remove('tabId');chrome.alarms.clear('orvlet');reply({ok:true});}
});
chrome.alarms.onAlarm.addListener(async alarm=>{if(alarm.name==='orvlet'&&(await chrome.storage.local.get('tabId')).tabId)start();});
chrome.tabs.onRemoved.addListener(async id=>{if((await chrome.storage.local.get('tabId')).tabId===id){running=false;clearTimeout(loopTimer);await chrome.storage.local.remove('tabId');}});
