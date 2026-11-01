"""Local deterministic fixtures; no remote requests or real model credentials."""
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
import json,math,wave,io,array
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
 def log_message(self,*args): pass
 def do_GET(self):
  if self.path.startswith('/tone.wav'):
   buf=io.BytesIO()
   with wave.open(buf,'wb') as f:
    f.setparams((1,2,22050,0,'NONE','not compressed'));f.writeframes(array.array('h',[int(1000*math.sin(i*2*math.pi*220/22050))for i in range(441000)]).tobytes())
   data=buf.getvalue();kind='audio/wav'
  elif self.path.startswith('/live-reading'):
   data=b'<html><head><title>Live status</title></head><body><h1 id="place">Test location</h1><output id="reading" style="font-size:50px">10:00:00</output><audio src="/tone.wav" preload="auto" style="display:none"></audio><script>let n=0;setInterval(()=>document.querySelector("#reading").textContent="10:00:"+String(++n).padStart(2,"0"),1000)</script></body></html>';kind='text/html'
  else:data=HTML.encode();kind='text/html'
  self.send_response(200);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 def do_POST(self):
  request=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  if self.path.endswith('/systemone'):
   result={'answers':{k:{'type':'noul','noul':.95 if k=='audio' else .1}for k in request['questions']}}
  else:
   plan={'components':[
    {'kind':'media'},
    {'kind':'transport','actions':[{'label':'Play / pause','icon':'playpause.fill','binding':{'action':'media','operation':'toggle'}},{'label':'Next','icon':'forward.end.fill','binding':{'action':'click','role':'button','name':'Next item'}}]},
    {'kind':'slider','valueSource':'mediaTime','binding':{'action':'media','operation':'seek'}},
    {'kind':'input','label':'Search','binding':{'action':'type','role':'input','name':'Search library'},'submit':{'action':'click','role':'button','name':'Search'}}
   ],'width':350,'height':280}
   plan['markup']={'html':'<section><h2 data-bind="title"></h2><button data-action="toggle" data-bind="toggleLabel"></button><button data-action="next">Next</button><input data-field="search" placeholder="Search library"><button data-action="search">Search</button></section>','compactHTML':'<div><button data-action="expand" data-bind="title"></button><button data-action="toggle" data-bind="toggleLabel"></button></div>','css':'section{display:grid;gap:8px}div{display:flex;gap:8px}','height':150}
   plan['actions']=[{'id':'toggle','binding':{'action':'media','operation':'toggle'}},{'id':'next','binding':{'action':'click','role':'button','name':'Next item'}},{'id':'search','binding':{'action':'type','role':'input','name':'Search library'},'submit':{'action':'click','role':'button','name':'Search'}}]
   result={'choices':[{'message':{'role':'assistant','content':json.dumps(plan)}}]}
  data=json.dumps(result).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
if __name__=='__main__':ThreadingHTTPServer(('127.0.0.1',19244),Handler).serve_forever()
