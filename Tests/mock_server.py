"""Local deterministic fixtures; no remote requests or real model credentials."""
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import json,math,wave,io,array,time,re
from model_api_fixture import respond as model_api_response
HTML='''<!doctype html><html><head><title>Test library</title></head><body>
<h1>Test library</h1><audio id="audio" controls src="/tone.wav"></audio>
<button onclick="document.title='Track Two';document.querySelector('#result').textContent='Track Two'">Next item</button>
<form onsubmit="event.preventDefault();document.querySelector('#result').textContent=this.q.value">
<input name="q" placeholder="Search library"><button>Search</button></form><p id="result"></p>
<input type="password" value="SHOULD_NOT_LEAK" aria-label="Password">
<canvas id="board" width="100" height="60" tabindex="0"></canvas>
<script>window.keyCount=0;document.addEventListener('keydown',()=>window.keyCount++);</script>
</body></html>'''
class Handler(BaseHTTPRequestHandler):
 fresh_reads=0
 def log_message(self,*args): pass
 def do_GET(self):
  if self.path.startswith('/deferred-reading'):
   value='second' if 'second' in self.path else 'first'
   data=('<html><body><output id="reading"></output><img src="/slow-image?'+value+'"><script>setTimeout(()=>document.querySelector("#reading").textContent="'+value+'",150)</script></body></html>').encode();kind='text/html'
  elif self.path.startswith('/slow-image'):
   time.sleep(3);data=b'';kind='image/png'
  elif self.path.startswith(('/tone.wav','/short-tone.wav')):
   buf=io.BytesIO()
   with wave.open(buf,'wb') as f:
    f.setparams((1,2,22050,0,'NONE','not compressed'));f.writeframes(array.array('h',[int(1000*math.sin(i*2*math.pi*220/22050))for i in range(132300 if self.path.startswith('/short-tone.wav') else 441000)]).tobytes())
   data=buf.getvalue();kind='audio/wav'
  elif self.path.startswith('/playback-end'):
   tag='video' if 'video' in self.path else 'audio'
   data=('<html><head><title>Playback end fixture</title></head><body><'+tag+' controls src="/short-tone.wav"></'+tag+'></body></html>').encode();kind='text/html'
  elif self.path.startswith('/fresh-data'):
   Handler.fresh_reads+=1
   data=('<html><head><title>Reading '+str(Handler.fresh_reads)+'</title></head><body><output id="value">'+str(Handler.fresh_reads)+'</output></body></html>').encode();kind='text/html'
  elif self.path.startswith('/data-form'):
   data=b'<html><head><title>Reference converter</title></head><body><main><form><select id="base"><option selected>HKD</option><option>USD</option></select><input id="amount" type="number" value="56"><select id="quote"><option selected>CNY</option><option>EUR</option></select><input id="converted" type="text" readonly value="47.60"><span id="updated">Daily reference</span><input id="private" type="password" value="synthetic-private"></form></main><nav><a href="/other"><span id="suggestion">USD</span></a></nav></body></html>';kind='text/html'
  elif self.path.startswith('/qualifier'):
   city='Beijing' if 'city=Beijing' in self.path else 'New York'
   data=('<html><head><title>Clock</title></head><body><main><h1 id="place">Time in '+city+'</h1><output id="clock">14:30:05</output></main><nav><a href="/qualifier?city=Beijing"><span id="suggestion">Beijing</span></a></nav></body></html>').encode();kind='text/html'
  elif self.path.startswith('/live-reading'):
   data=b'<html><head><title>Live status</title></head><body><h1 id="place">Test location</h1><output id="reading" style="font-size:50px">10:00:00</output><audio src="/tone.wav" preload="auto" style="display:none"></audio><script>let n=0;setInterval(()=>document.querySelector("#reading").textContent="10:00:"+String(++n).padStart(2,"0"),1000)</script></body></html>';kind='text/html'
  else:data=HTML.encode();kind='text/html'
  # Serve media byte ranges for real WebKit seeking and replay.
  partial=re.fullmatch(r'bytes=(\d+)-(\d*)', self.headers.get('Range','')) if kind=='audio/wav' else None
  total=len(data)
  if partial:
   start=int(partial[1]);end=min(int(partial[2]) if partial[2] else total-1,total-1)
   data=data[start:end+1];self.send_response(206);self.send_header('Content-Range',f'bytes {start}-{end}/{total}')
  else:self.send_response(200)
  if kind=='audio/wav':self.send_header('Accept-Ranges','bytes')
  self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  if self.path.startswith('/api-wire/'):
   try: status,result=model_api_response(self.path,request,self.headers)
   except (AssertionError,KeyError,TypeError) as error: status,result=422,{'error':{'message':'Wire fixture rejected request: '+str(error)}}
   data=json.dumps(result).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
   return
  if self.path.startswith('/slow/'):
   time.sleep(2)
  if self.path.startswith('/ownership/'):
   context=json.loads(next(m['content'].removeprefix('Request context: ') for m in request['messages'] if m.get('content','').startswith('Request context: ')))
   assert context['routeResolved'] is False and context['resolvedTaskID']=='', 'Advisory target was locked'
   assert len(context['tasks'])==2 and context['suggestedTaskID'], 'Competing purposes must remain visible'
   assert not any(m.get('content','').startswith(('Recent task conversation:', 'Task state:')) for m in request['messages']), 'Wrong owner contaminated planning context'
   properties=request['tools'][0]['function']['parameters']['properties']
   assert 'targetTaskID' in properties and None in properties['targetTaskID']['enum'], 'Interpreter must be allowed to choose a new task'
   music='放另一首歌' in request['messages'][-1]['content']
   target=next(t['id'] for t in context['tasks'] if t['media']) if music else None
   intent={'kind':'general','route':'web' if music else 'api','behavior':'snapshot','taskAction':'perform','requiresFreshData':True,'targetTaskID':target,'requirements':[],'reuse':None,'goals':['Play another song' if music else 'Check tomorrow weather'],'steps':[],'stepsComplete':False}
   intent={k:v for k,v in intent.items() if k in properties}
   result={'choices':[{'message':{'role':'assistant','tool_calls':[{'id':'ownership','type':'function','function':{'name':'interpret_request','arguments':json.dumps(intent)}}]}}]}
  elif self.path.startswith('/planning/'):
   context=json.loads(next(m['content'].removeprefix('Request context: ') for m in request['messages'] if m.get('content','').startswith('Request context: ')))
   method=context['methods'][0]
   assert 'inputs' in method and 'sourceFields' in method
   assert context['routeResolved'] is False and context['tasks'], 'Advisory ownership needs a purpose check'
   assert len(json.dumps(request).encode()) < 20000, 'Initial request exceeded the fixture budget'
   state={'amount':'100','fromCurrency':'USD','toCurrency':'CNY'}
   intent={'goals':['Convert the requested amount using current reference rates'],'kind':'general','route':'api','requiresFreshData':True,'targetTaskID':context['tasks'][0]['id'], 'behavior':'snapshot','taskAction':'perform','summary':'Converting amount','playbackIntent':'none','needsBrowserContext':False,'contextDetail':'state','timerSeconds':None,'timerEvidence':None,'reuse':{'id':method['id'],'state':state},
    'requirements':[{'label':'base','anyOf':['USD']},{'label':'quote','anyOf':['CNY']}],
    'steps':[], 'stepsComplete':True}
   allowed=request['tools'][0]['function']['parameters']['properties']
   intent={k:v for k,v in intent.items() if k in allowed}
   result={'choices':[{'message':{'role':'assistant','tool_calls':[{'id':'plan','type':'function','function':{'name':'interpret_request','arguments':json.dumps(intent)}}]}}]}
  elif self.path.startswith('/required-tool/'):
   forced=request.get('tool_choice')=={'type':'function','function':{'name':'interpret_request'}} and request.get('parallel_tool_calls') is False
   message={'role':'assistant','content':'I can help with that.'}
   if forced: message={'role':'assistant','tool_calls':[{'id':'intent','type':'function','function':{'name':'interpret_request','arguments':json.dumps({'kind':'general','playbackIntent':'play'})}}]}
   result={'choices':[{'message':message}]}
  elif self.path.endswith('/systemone') and 'route' in request['questions']:
   answers={}
   for name,q in request['questions'].items():
    selected={'route':'task_0','budget':'low','control':'pause','capability':'control','instance':'automatic'}[name]
    answers[name]={'type':'choice','choice':selected,'confidence':1,'probabilities':{k:1 if k==selected else 0 for k in q['criteria']}}
   result={'answers':answers}
  elif self.path.endswith('/systemone'):
   result={'answers':{k:{'type':'noul','noul':.95 if k=='audio' else .1}for k in request['questions']}}
  else:
   plan={'components':[
    {'kind':'media'},
    {'kind':'transport','actions':[{'label':'Play / pause','icon':'playpause.fill','binding':{'action':'media','operation':'toggle'}},{'label':'Next','icon':'forward.end.fill','binding':{'action':'click','role':'button','name':'Next item'}}]},
    {'kind':'slider','valueSource':'mediaTime','binding':{'action':'media','operation':'seek'}},
    {'kind':'input','label':'Search','binding':{'action':'type','role':'input','name':'Search library'},'submit':{'action':'click','role':'button','name':'Search'}}
   ],'width':350,'height':280}
   plan['markup']={'html':'<section><h2 data-bind="title"></h2><small data-bind="status"></small><button data-action="toggle" data-bind="toggleLabel"></button><button data-action="next">Next</button><input data-field="search" placeholder="Search library"><button data-action="search">Search</button></section>','compactHTML':'<div><button data-action="expand" data-bind="title"></button><button data-action="toggle" data-bind="toggleLabel"></button></div>','css':'section{display:grid;gap:8px}div{display:flex;gap:8px}','height':150}
   plan['actions']=[{'id':'toggle','binding':{'action':'media','operation':'toggle'}},{'id':'next','binding':{'action':'click','role':'button','name':'Next item'}},{'id':'search','binding':{'action':'type','role':'input','name':'Search library'},'submit':{'action':'click','role':'button','name':'Search'}}]
   result={'choices':[{'message':{'role':'assistant','content':json.dumps(plan)}}]}
  data=json.dumps(result).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
if __name__=='__main__':ThreadingHTTPServer(('127.0.0.1',19244),Handler).serve_forever()
