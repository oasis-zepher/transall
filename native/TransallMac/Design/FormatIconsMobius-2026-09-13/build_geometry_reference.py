"""Generate a true parametric Möbius surface as a geometry reference, not a paint edit."""
from pathlib import Path
import math
import json
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parent
SIZE=1200
R=2.8
HALF_WIDTH=0.92
NU,NV=480,32
u=np.linspace(0,2*np.pi,NU+1)
v=np.linspace(-HALF_WIDTH,HALF_WIDTH,NV+1)
U,V=np.meshgrid(u,v,indexing='ij')
P=np.stack(((R+V*np.cos(U/2))*np.cos(U), (R+V*np.cos(U/2))*np.sin(U), V*np.sin(U/2)),axis=-1)
du=np.stack((-(R+V*np.cos(U/2))*np.sin(U)-V/2*np.sin(U/2)*np.cos(U), (R+V*np.cos(U/2))*np.cos(U)-V/2*np.sin(U/2)*np.sin(U), V/2*np.cos(U/2)),axis=-1)
dv=np.stack((np.cos(U/2)*np.cos(U),np.cos(U/2)*np.sin(U),np.sin(U/2)),axis=-1)
normal=np.cross(du,dv)
normal/=np.linalg.norm(normal,axis=-1,keepdims=True)

az,el=np.deg2rad(float(sys.argv[1]) if len(sys.argv)>1 else 35),np.deg2rad(float(sys.argv[2]) if len(sys.argv)>2 else 48)
view=np.array([np.cos(el)*np.cos(az),np.cos(el)*np.sin(az),np.sin(el)])
right=np.array([-np.sin(az),np.cos(az),0])
up=np.cross(view,right)
Q=np.stack((P@right,-P@up,P@view),axis=-1)
scale=SIZE*0.76/(Q[:,:,:2].max((0,1))-Q[:,:,:2].min((0,1))).max()
mid=(Q[:,:,:2].max((0,1))+Q[:,:,:2].min((0,1)))/2
Q[:,:,:2]=(Q[:,:,:2]-mid)*scale+SIZE/2

# Icons are texture coordinates on the same surface; none float outside it.
TW,TH=240,300
formats=[('W','#2474D5'),('P','#EA7432'),('X','#26905E'),('PDF','#D64B45'),('TXT','#8493A6'),('IMG','#8A75C7')]*2
tex=Image.new('RGB',(TW*len(formats),TH),'#F4F5F7')
td=ImageDraw.Draw(tex)
f=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf',78)
small=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial Bold.ttf',52)
for n,(label,color) in enumerate(formats):
    x=n*TW
    td.rounded_rectangle((x+3,3,x+TW-3,TH-3),radius=19,fill=color)
    ff=f if len(label)==1 else small
    box=td.textbbox((0,0),label,font=ff)
    td.text((x+(TW-(box[2]-box[0]))/2,57),label,font=ff,fill='white')
    if label=='X':
        for xx in [54,98,142,186]: td.line((x+xx,171,x+xx,243),fill='white',width=4)
        for yy in [171,195,219,243]: td.line((x+54,yy,x+186,yy),fill='white',width=4)
    elif label=='P':
        td.arc((x+58,166,x+121,230),0,300,fill='white',width=9)
        td.rectangle((x+139,176,x+151,235),fill='white')
        td.rectangle((x+164,202,x+176,235),fill='white')
    else:
        for yy in [177,203,229]: td.rounded_rectangle((x+57,yy,x+183,yy+7),radius=3,fill='white')
texture=np.asarray(tex)
out=np.full((SIZE,SIZE,3),[246,247,249],dtype=np.float32)
depth=np.full((SIZE,SIZE),-np.inf)
light=np.array([-0.4,-0.6,1.7]);light/=np.linalg.norm(light)
uv=np.stack((U/(2*np.pi)*(texture.shape[1]-1),(V+HALF_WIDTH)/(2*HALF_WIDTH)*(TH-1)),axis=-1)

def triangle(indices):
    pts=np.array([Q[i,j] for i,j in indices])
    norms=np.array([normal[i,j] for i,j in indices])
    coords=np.array([uv[i,j] for i,j in indices])
    xmin=max(0,int(np.floor(pts[:,0].min())));xmax=min(SIZE-1,int(np.ceil(pts[:,0].max())))
    ymin=max(0,int(np.floor(pts[:,1].min())));ymax=min(SIZE-1,int(np.ceil(pts[:,1].max())))
    if xmax<xmin or ymax<ymin:return
    xx,yy=np.meshgrid(np.arange(xmin,xmax+1)+0.5,np.arange(ymin,ymax+1)+0.5)
    a,b,c=pts
    den=(b[1]-c[1])*(a[0]-c[0])+(c[0]-b[0])*(a[1]-c[1])
    if abs(den)<1e-8:return
    w0=((b[1]-c[1])*(xx-c[0])+(c[0]-b[0])*(yy-c[1]))/den
    w1=((c[1]-a[1])*(xx-c[0])+(a[0]-c[0])*(yy-c[1]))/den
    w2=1-w0-w1
    z=w0*a[2]+w1*b[2]+w2*c[2]
    target=depth[ymin:ymax+1,xmin:xmax+1]
    valid=(w0>=-1e-6)&(w1>=-1e-6)&(w2>=-1e-6)&(z>target)
    if not valid.any():return
    tx=np.clip((w0*coords[0,0]+w1*coords[1,0]+w2*coords[2,0]).astype(int),0,texture.shape[1]-1)
    ty=np.clip((w0*coords[0,1]+w1*coords[1,1]+w2*coords[2,1]).astype(int),0,TH-1)
    nn=w0[...,None]*norms[0]+w1[...,None]*norms[1]+w2[...,None]*norms[2]
    nn/=np.maximum(1e-8,np.linalg.norm(nn,axis=-1,keepdims=True))
    nn*=np.where((nn@view)[...,None]>=0,1,-1)
    shade=0.52+0.48*np.maximum(0,nn@light)
    colors=texture[ty,tx]*shade[...,None]
    out[ymin:ymax+1,xmin:xmax+1][valid]=colors[valid]
    target[valid]=z[valid]

for i in range(NU):
    for j in range(NV):
        triangle([(i,j),(i+1,j),(i+1,j+1)])
        triangle([(i,j),(i+1,j+1),(i,j+1)])
image_name=sys.argv[3] if len(sys.argv)>3 else 'geometry-reference.png'
Image.fromarray(np.clip(out,0,255).astype('uint8')).save(ROOT/image_name)

# Explicit seam reversal verifies the half twist, unlike a cylindrical belt.
seam_error=float(np.abs(P[0]-P[-1,::-1]).max())
assert seam_error<1e-12
assert float(np.abs(P[0]-P[-1]).max())>1
(ROOT/'geometry-reference.json').write_text(json.dumps({'surface':'Möbius','formula':'((R+v*cos(u/2))*cos(u), (R+v*cos(u/2))*sin(u), v*sin(u/2))','u_range':[0,2*math.pi],'v_range':[-HALF_WIDTH,HALF_WIDTH],'radius':R,'seam':'P(0,v) = P(2*pi,-v)','seam_error':seam_error,'half_twists':1,'texture_tiles':len(formats)},indent=2)+'\n')
print(ROOT/image_name)
