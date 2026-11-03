"""Generates App/AppIcon.png (1024x1024, RGB, no alpha) for RIFFNEX.

Concept: the practice screen's ring. A riff caught in a loop, the guitar's loudness in
orange and the band's in cyan around it, the speed meter outside and the playhead at the top.
Run: python3 tools/make_icon.py   (needs Pillow)
"""
import math, random
from PIL import Image, ImageDraw, ImageFilter
S=1024; random.seed(7)
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
bg=Image.new('RGB',(S,S))
px=bg.load()
c1=(40,22,88); c2=(13,10,31); c3=(5,4,12)
for y in range(S):
    for x in range(S):
        d=math.hypot(x-S*0.5,y-S*0.46)/(S*0.72)
        px[x,y]=lerp(c1,c2,min(1,d/0.55)) if d<0.55 else lerp(c2,c3,min(1,(d-0.55)/0.45))
glow=Image.new('RGBA',(S,S),(0,0,0,0)); g=ImageDraw.Draw(glow)
sharp=Image.new('RGBA',(S,S),(0,0,0,0)); d=ImageDraw.Draw(sharp)
cx,cy,R=S/2,S/2,S*0.255
fire=(255,106,43); fire2=(255,194,61); cyan=(51,225,255); mag=(255,61,154)
# envelopes: riff plucks
N=132
def env(i, kind):
    t=i/N
    v=0
    for p in [0,0.125,0.19,0.31,0.375,0.5,0.625,0.69,0.81,0.875]:
        if t>=p: v+=math.exp(-(t-p)/(0.035 if kind=='g' else 0.02))
    return min(1,0.15+0.75*(1-math.exp(-v*1.4)))
for i in range(N):
    th=-math.pi/2+i/N*2*math.pi
    cs,sn=math.cos(th),math.sin(th)
    hb=env((i+3)%N,'b')*0.85; hg=env(i,'g')
    for h,col,k,w in [(hb,cyan,1.0,9),(hg,fire,0.8,10)]:
        ro=R+h*S*0.12*k; ri=R-h*S*0.065*k
        seg=[(cx+cs*ri,cy+sn*ri),(cx+cs*ro,cy+sn*ro)]
        g.line(seg,fill=col+(255,),width=w*3)
        d.line(seg,fill=col+(255,),width=w)
# speed meter arcs
Ro=R+S*0.17
segs=12
for i in range(segs):
    a0=-90+i*30+3; a1=-90+(i+1)*30-3
    lit=i<9
    col=(mag if i>=8 else fire if i>=5 else fire2) if lit else (60,52,100)
    box=[cx-Ro,cy-Ro,cx+Ro,cy+Ro]
    if lit: g.arc(box,a0,a1,fill=col+(255,),width=54)
    d.arc(box,a0,a1,fill=col+(255,),width=22 if lit else 14)
# playhead
d.rounded_rectangle([cx-7,cy-R-S*0.15,cx+7,cy-R+S*0.06],radius=6,fill=(255,255,255,255))
g.rounded_rectangle([cx-14,cy-R-S*0.15,cx+14,cy-R+S*0.06],radius=10,fill=(255,61,154,255))
glow=glow.filter(ImageFilter.GaussianBlur(26))
out=bg.convert('RGBA')
# dim glow
gl=glow.copy(); a=gl.split()[3].point(lambda v:int(v*0.55)); gl.putalpha(a)
out=Image.alpha_composite(out,gl); out=Image.alpha_composite(out,sharp)
# center spark
cg=Image.new('RGBA',(S,S),(0,0,0,0)); cd=ImageDraw.Draw(cg)
cd.ellipse([cx-60,cy-60,cx+60,cy+60],fill=(255,194,61,140)); cg=cg.filter(ImageFilter.GaussianBlur(40))
out=Image.alpha_composite(out,cg)
cd2=ImageDraw.Draw(out); cd2.ellipse([cx-26,cy-26,cx+26,cy+26],fill=(255,240,220,255))
out.convert('RGB').save('App/AppIcon.png')
