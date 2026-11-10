from pathlib import Path
import math
from html import escape
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor

OUT = Path('/Users/dianjin/Local/scripts/Tometo/output/pdf')
W, H = 1600, 1080
S = 518.4 / W  # 7.2-inch, double-column figure; typography remains readable at print size.
FONT = Path('/opt/homebrew/lib/python3.14/site-packages/matplotlib/mpl-data/fonts/ttf')
pdfmetrics.registerFont(TTFont('Diagram', str(FONT/'DejaVuSans.ttf')))
pdfmetrics.registerFont(TTFont('DiagramBold', str(FONT/'DejaVuSans-Bold.ttf')))
pdf = canvas.Canvas(str(OUT/'orvlet-system-architecture.pdf'), pagesize=(W*S,H*S))
pdf.setTitle('Orvlet: task-centered system architecture')
pdf.setAuthor('Orvlet')
pdf.scale(S,S)
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" role="img" aria-labelledby="title desc">',
       '<title id="title">Orvlet system architecture</title>',
       '<desc id="desc">Natural-language requests enter task orchestration; an optional Jev service provides routing and effort advice. The main model interprets requests, selects tools and designs. On-device adapters execute and verify actions. A reusable card system binds current task values to compact and expanded views. Direct card controls bypass model inference. Task state, conversations and interface recipes persist locally.</desc>']
INK='#233343'; MUTED='#5E6D7A'; LINE='#A6B2BB'; SOFT='#F7F9FA'
BLUE='#365F86'; BLUEFILL='#F0F5FA'; TEAL='#286C67'; TEALFILL='#F0F7F5'
VIOLET='#766084'; VIOLETFILL='#F7F3F9'; WHITE='#FFFFFF'

def rect(x,y,w,h,fill=WHITE,stroke=LINE,r=9,lw=1.6,dash=False):
    pdf.setLineWidth(lw); pdf.setStrokeColor(HexColor(stroke)); pdf.setFillColor(HexColor(fill))
    pdf.setDash([7,5] if dash else [])
    pdf.roundRect(x,H-y-h,w,h,r,stroke=1,fill=1)
    svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="{lw}"'+(' stroke-dasharray="7 5"' if dash else '')+'/>')

def text(x,y,t,size=23,color=INK,bold=False,anchor='start',maxw=None):
    font='DiagramBold' if bold else 'Diagram'
    tw=pdfmetrics.stringWidth(t,font,size)
    if maxw is not None and tw>maxw: raise ValueError(f'Text too wide: {t}: {tw:.1f}>{maxw}')
    pdf.setFillColor(HexColor(color)); pdf.setFont(font,size)
    xx=x if anchor=='start' else x-tw/2 if anchor=='middle' else x-tw
    pdf.drawString(xx,H-y,t)
    svg.append(f'<text x="{x}" y="{y}" fill="{color}" font-family="DejaVu Sans, Arial, sans-serif" font-size="{size}" font-weight="{700 if bold else 400}" text-anchor="{anchor}">{escape(t)}</text>')

def path(points,color=INK,lw=2,dash=False,arrow=True,both=False):
    p=pdf.beginPath();p.moveTo(points[0][0],H-points[0][1])
    for x,y in points[1:]:p.lineTo(x,H-y)
    pdf.setStrokeColor(HexColor(color));pdf.setLineWidth(lw);pdf.setDash([7,5] if dash else [])
    pdf.drawPath(p)
    svg.append(f'<polyline points="'+ ' '.join(f'{x},{y}' for x,y in points)+f'" fill="none" stroke="{color}" stroke-width="{lw}"'+(' stroke-dasharray="7 5"' if dash else '')+'/>')
    def head(end,previous):
        a=math.atan2(end[1]-previous[1],end[0]-previous[0]);length=10;half=4.3
        tri=[end,(end[0]-length*math.cos(a)+half*math.sin(a),end[1]-length*math.sin(a)-half*math.cos(a)),(end[0]-length*math.cos(a)-half*math.sin(a),end[1]-length*math.sin(a)+half*math.cos(a))]
        q=pdf.beginPath();q.moveTo(tri[0][0],H-tri[0][1])
        for x,y in tri[1:]:q.lineTo(x,H-y)
        q.close();pdf.setFillColor(HexColor(color));pdf.drawPath(q,fill=1,stroke=0)
        svg.append('<polygon points="'+' '.join(f'{x},{y}' for x,y in tri)+f'" fill="{color}"/>')
    if arrow:head(points[-1],points[-2])
    if both:head(points[0],points[1])

def line(x,y,w):path([(x,y),(x+w,y)],LINE,1,arrow=False)

# Remote intelligence is outside the local execution/state boundary.
text(28,42,'Orvlet',31,bold=True)
text(28,73,'System architecture',22,MUTED)
text(300,40,'REMOTE MODEL SERVICES',21,MUTED,bold=True)
rect(300,65,570,135,BLUEFILL,BLUE)
text(326,100,'Main model',27,BLUE,True)
text(326,136,'Intent interpretation · tool planning',23,maxw=520)
text(326,171,'Saved-design selection · UI generation',23,maxw=520)
rect(930,65,600,135,VIOLETFILL,VIOLET,dash=True)
text(956,100,'Jev  /  optional',27,VIOLET,True)
text(956,136,'Task routing · reasoning-effort advice',23,maxw=548)
text(956,171,'Selected direct controls · task ranking',23,maxw=548)

rect(265,310,1300,700,'#FCFDFE',LINE,r=13,lw=1.8)
text(285,342,'ON DEVICE',21,MUTED,True)

# Model request/response and optional advice routes use separate ports.
path([(465,200),(465,365)],BLUE,both=True)
text(450,243,'Context / intent,',20,BLUE,anchor='end')
text(450,269,'tools & design',20,BLUE,anchor='end')
path([(1030,200),(1030,235),(580,235),(580,365)],VIOLET,dash=True)
text(755,222,'Routing / effort advice',20,VIOLET,anchor='middle')
path([(1370,200),(1370,365)],VIOLET,dash=True)
text(1355,258,'Ordering advice',20,VIOLET,anchor='end')

# User input is a first-class, visually explicit leftmost entry point.
text(120,360,'USER',24,INK,True,anchor='middle')
rect(25,465,190,105,INK,INK,r=10)
text(120,499,'USER INPUT',24,WHITE,True,anchor='middle',maxw=176)
text(120,527,'Natural language',18,WHITE,anchor='middle',maxw=176)
text(120,553,'Global / task chat',18,WHITE,anchor='middle',maxw=176)
path([(215,515),(300,515)],INK,lw=2.7)

rect(25,680,190,97,TEALFILL,TEAL,r=10)
text(120,714,'Card controls',20,TEAL,True,anchor='middle',maxw=176)
text(120,746,'Buttons / fields',20,TEAL,anchor='middle',maxw=176)
path([(120,680),(120,570)],INK,lw=1.8)
text(135,624,'AI actions',20,MUTED)
path([(215,728),(244,728),(244,802),(1060,802),(1060,765)],TEAL,lw=2.5)
text(680,830,'Bound actions · model-free execution',22,TEAL,anchor='middle')

# Three main local subsystems.
rect(300,365,330,400,WHITE,LINE)
text(322,402,'Task orchestration',25,INK,True,maxw=288)
line(322,421,286)
text(322,459,'Ownership & context',23,bold=True,maxw=288)
text(322,490,'New vs. existing task',21,MUTED,maxw=288)
text(322,520,'Task-scoped conversation',21,MUTED,maxw=288)
text(322,567,'Request control',23,bold=True,maxw=288)
text(322,598,'Clarification · queue · steer',21,MUTED,maxw=288)
text(322,628,'Scoped tool dispatch',21,MUTED,maxw=288)
text(322,680,'Lifecycle & revisions',23,bold=True,maxw=288)
text(322,711,'Cancel / reject stale results',20,MUTED,maxw=288)
text(322,741,'Completion receipts',21,MUTED,maxw=288)

path([(630,515),(690,515)],INK,both=True)
text(660,492,'Calls',20,MUTED,anchor='middle')
text(660,546,'Data',20,MUTED,anchor='middle')

rect(690,365,420,400,WHITE,LINE)
text(714,402,'Capability execution',25,INK,True,maxw=372)
line(714,421,372)
tools=[('Browser adapter','Observe · act · media playback'),
       ('Public data adapter','Fetch · validate identity · derive'),
       ('Local worker & runtime','JavaScript · clocks · countdowns'),
       ('Calendar adapter','Deduplicate · create · read back')]
for i,(title,desc) in enumerate(tools):
    y=437+i*65
    text(714,y+20,title,23,bold=True,maxw=372)
    text(714,y+46,desc,20,MUTED,maxw=372)
rect(710,710,380,36,SOFT,LINE,r=5,lw=1)
text(900,735,'Outcome / behavior checks',20,INK,True,anchor='middle',maxw=360)

path([(1110,515),(1170,515)],INK)
text(1140,462,'Live',20,MUTED,anchor='middle')
text(1140,490,'state',20,MUTED,anchor='middle')

rect(1170,365,360,400,WHITE,TEAL)
text(1192,402,'Calm task interface',25,TEAL,True,maxw=316)
line(1192,421,316)
for y,label in [(438,'Validated cache / saved recipe'),(485,'Built-in card library'),(532,'New model-generated design')]:
    rect(1190,y,320,37,TEALFILL,'#BACDC9',r=5,lw=1)
    text(1350,y+25,label,19.4,INK,anchor='middle',maxw=306)
text(1350,599,'Validate live bindings',22,INK,True,anchor='middle',maxw=320)
path([(1350,609),(1350,630)],TEAL,lw=1.8)
rect(1190,635,150,59,SOFT,LINE,r=5,lw=1)
rect(1360,635,150,59,SOFT,LINE,r=5,lw=1)
text(1265,660,'Compact',21,INK,True,anchor='middle')
text(1265,682,'glance',19,MUTED,anchor='middle')
text(1435,660,'Expanded',21,INK,True,anchor='middle')
text(1435,682,'task card',19,MUTED,anchor='middle')
text(1350,736,'Source view on demand',20,MUTED,anchor='middle',maxw=320)

# State/persistence is shared infrastructure, not another inference stage.
path([(1140,515),(1140,870)],MUTED,dash=True,both=True)
text(1125,847,'Task state',19,MUTED,anchor='end')
path([(1400,765),(1400,870)],MUTED,dash=True,both=True)
text(1385,824,'Save / restore',19,MUTED,anchor='end')
rect(300,870,1230,116,SOFT,LINE,r=8)
text(323,901,'SHARED LOCAL STATE & PERSISTENCE',20,MUTED,True)
text(323,938,'Task state & lifecycle',23,INK,True,maxw=350)
text(323,968,'Inputs · sources · execution state',20,MUTED,maxw=350)
text(739,938,'Conversation & sessions',23,INK,True,maxw=370)
text(739,968,'History · drafts · restoration',20,MUTED,maxw=370)
text(1160,938,'Interface memory',23,INK,True,maxw=340)
text(1160,968,'Recipes · bindings · page cache',20,MUTED,maxw=340)

# Restrained semantic line legend, with no speculative future paths.
path([(300,1045),(345,1045)],INK,lw=2)
text(358,1052,'Task / data flow',20,MUTED)
path([(610,1045),(655,1045)],TEAL,lw=2.5)
text(668,1052,'Direct interaction',20,MUTED)
path([(952,1045),(997,1045)],MUTED,lw=2,dash=True)
text(1010,1052,'Advice / shared-state access',20,MUTED)

pdf.showPage();pdf.save()
svg.append('</svg>')
(OUT/'orvlet-system-architecture.svg').write_text('\n'.join(svg))
print(OUT/'orvlet-system-architecture.pdf')
