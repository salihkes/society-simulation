"""Read the active baked terrain and render an overview plus a deformation comparison.

No rebaking or scene changes. Run from the repository root:
python tools/bake/regionforge/render_overview.py
"""
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy.ndimage import map_coordinates

from build_region import DEFAULT_OUT, HERE, Projection
from city_stamps import BaseField, smooth
from overlay_mapping import OverlayMapping

ROOT=HERE.parents[2]
OUT=ROOT/'output/terrain-overview'
FONT='/System/Library/Fonts/Helvetica.ttc'
BG='#12232b'
INK='#edf4ef'
MUTED='#b1c5c7'
ACCENT='#ffd184'
TEAL='#66dbcf'


def font(size):
    try:return ImageFont.truetype(FONT,size)
    except OSError:return ImageFont.load_default(size=size)


def text(draw,xy,value,size=24,fill=INK):
    draw.text(xy,value,font=font(size),fill=fill)


def relief(h,sea,step):
    height=h-sea
    levels=np.array([-100,-30,0,.1,75,200,450,800,1400,2200])
    colors=np.array([[15,46,66],[19,61,83],[30,83,105],[85,130,103],[109,145,104],[153,159,112],[177,157,122],[185,178,161],[220,220,209],[242,243,233]])/255
    rgb=np.stack([np.interp(height,levels,colors[:,c]) for c in range(3)],axis=-1)
    # The sea is a flat surface in-game. Do not turn changes of bathymetry
    # source into apparent coast/terrain seams on this surface overview.
    rgb[height<=0]=np.array([19,55,74])/255
    dz,dx=np.gradient(h,step)
    shade=np.clip((1-dx*.55-dz*.7)/np.sqrt(1+dx*dx+dz*dz),.38,1.24)
    shade=np.where(height>0,shade,1.)
    return np.uint8(np.clip(rgb*shade[...,None],0,1)*255)


def assemble(meta,res=16):
    x0,z0,x1,z1=meta['tile_bounds'];s=meta['quads']+3
    h=np.empty(((z1-z0)*res,(x1-x0)*res),np.float32)
    stride=meta['quads']//res
    pages={}
    for tz in range(z0,z1):
        for tx in range(x0,x1):
            key=(tx//meta['page_side'],tz//meta['page_side'])
            if key not in pages:
                p=DEFAULT_OUT/meta['tiles_dir']/f'{key[0]}_{key[1]}.bin'
                pages[key]=np.memmap(p,dtype='<f4',mode='r',shape=(16,16,s,s))
            data=pages[key][tz%16,tx%16]
            h[(tz-z0)*res:(tz-z0+1)*res,(tx-x0)*res:(tx-x0+1)*res]=data[1:-2:stride,1:-2:stride]
    before=h.copy()
    for key,path in meta['tile_overrides'].items():
        tx,tz=map(int,key.split('_'));data=np.fromfile(DEFAULT_OUT/path,dtype='<f4').reshape(s,s)
        h[(tz-z0)*res:(tz-z0+1)*res,(tx-x0)*res:(tx-x0+1)*res]=data[1:-2:stride,1:-2:stride]
    print('Read complete baked map',h.shape,flush=True)
    return before,h


class View:
    def __init__(self,meta,bounds,width,height):
        self.angle=math.radians(meta['projection']['bearing_x_deg'])
        self.sin,self.cos=math.sin(self.angle),math.cos(self.angle)
        self.bounds=bounds # east, north coordinates, in terrain units
        self.width,self.height=width,height
        self.upp=max((bounds[2]-bounds[0])/width,(bounds[3]-bounds[1])/height)
        self.e=(bounds[0]+bounds[2])/2
        self.n=(bounds[1]+bounds[3])/2

    def world(self):
        e=(np.arange(self.width)-self.width/2)*self.upp+self.e
        n=(self.height/2-np.arange(self.height))*self.upp+self.n
        e,n=np.meshgrid(e,n)
        return e*self.sin+n*self.cos,e*self.cos-n*self.sin

    def point(self,x,z):
        e=x*self.sin+z*self.cos;n=x*self.cos-z*self.sin
        return ((e-self.e)/self.upp+self.width/2,self.height/2-(n-self.n)/self.upp)

    def circle(self,draw,x,z,r,color,width=2):
        px,py=self.point(x,z);rr=r/self.upp
        draw.ellipse([px-rr,py-rr,px+rr,py+rr],outline=color,width=width)


def resample(h,x,z,meta,res=16):
    x0,z0,_,_=meta['tile_bounds'];upp=meta['tile_size']/res
    coords=[(z-z0*meta['tile_size'])/upp,(x-x0*meta['tile_size'])/upp]
    sampled=map_coordinates(h,coords,order=1,mode='nearest')
    valid=(coords[0]>=0)&(coords[1]>=0)&(coords[0]<h.shape[0]-1)&(coords[1]<h.shape[1]-1)
    return sampled,valid


def mark_city(draw,view,p,name,offset,color):
    x,y=view.point(p[0],p[1]);draw.ellipse([x-6,y-6,x+6,y+6],fill=color,outline=BG,width=2)
    tx,ty=x+offset[0],y+offset[1]
    draw.line([(x,y),(tx-9,ty+14)],fill=color,width=2)
    text(draw,(tx,ty),name,26,color)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    meta=json.loads((DEFAULT_OUT/'meta.json').read_text());city=meta['cities'][0]
    base,active=assemble(meta)
    x0,z0,x1,z1=np.array(meta['tile_bounds'])*meta['tile_size']
    a=math.radians(meta['projection']['bearing_x_deg']);sin,cos=math.sin(a),math.cos(a)
    corners=np.array([[x0,z0],[x0,z1],[x1,z0],[x1,z1]])
    e=corners[:,0]*sin+corners[:,1]*cos;n=corners[:,0]*cos-corners[:,1]*sin
    bounds=[e.min(),n.min(),e.max(),n.max()]
    view=View(meta,bounds,2280,2280)
    x,z=view.world();h,valid=resample(active,x,z,meta)
    rgb=relief(h,meta['sea_y'],view.upp);rgb[~valid]=[18,35,43]
    overview=Image.fromarray(rgb);draw=ImageDraw.Draw(overview)
    p=np.array(city['position'])[[0,2]]
    view.circle(draw,*p,city['outer_radius'],ACCENT,3)
    view.circle(draw,*p,city['inner_radius'],TEAL,2)
    mark_city(draw,view,meta['projection']['anchor_xz'],'Original city',(-230,-45),INK)
    mark_city(draw,view,p,'Fitted city',(55,-20),ACCENT)
    # Frame follows the actual rotated baked rectangle, not a political border.
    frame=[view.point(*q) for q in corners[[0,1,3,2,0]]]
    draw.line(frame,fill='#59727a',width=2)
    canvas=Image.new('RGB',(2400,2510),BG);canvas.paste(overview,(60,135));d=ImageDraw.Draw(canvas)
    text(d,(60,32),'Entire baked terrain',46)
    text(d,(60,91),'North-oriented view · actual game-space proportions · active city terrain included',25,MUTED)
    d.line([(60,2448),(110,2448)],fill=TEAL,width=4);text(d,(126,2432),'Approved fit',24)
    d.line([(360,2448),(410,2448)],fill=ACCENT,width=4);text(d,(426,2432),'Outer blend limit',24)
    text(d,(900,2432),'Outside the amber ring: unchanged by this city fit',24,MUTED)
    canvas.save(OUT/'entire-terrain.png')

    # Read the full-resolution actual tiles around the affected area.
    center=np.array(city['position'])[[0,2]];radius=8200.
    low=np.floor((center-radius)/meta['tile_size']).astype(int)
    high=np.ceil((center+radius)/meta['tile_size']).astype(int)
    local_meta=dict(meta,tile_bounds=[*low,*high])
    local_base,local_active=assemble(local_meta,res=64)
    ce=center[0]*sin+center[1]*cos;cn=center[0]*cos-center[1]*sin
    view=View(meta,[ce-radius,cn-radius,ce+radius,cn+radius],980,980)
    x,z=view.world();old,_=resample(local_base,x,z,local_meta,res=64);new,_=resample(local_active,x,z,local_meta,res=64)
    panels=[]
    for data in [old,new]:
        im=Image.fromarray(relief(data,meta['sea_y'],view.upp));dr=ImageDraw.Draw(im)
        view.circle(dr,*center,city['outer_radius'],ACCENT,3)
        view.circle(dr,*center,city['inner_radius'],TEAL,2)
        # Outline actual model footprint in model coordinates. No coastline inference.
        mapping=OverlayMapping(city['accepted_overlay'],Projection(meta['projection'],meta['projection']['far_compression']))
        corners=mapping.model_to_world(np.array([[-1082.42,-669.619],[763.818,-669.619],[763.818,772.198],[-1082.42,772.198],[-1082.42,-669.619]]))
        dr.line([view.point(*q) for q in corners],fill=INK,width=2)
        panels.append(im)
    compare=Image.new('RGB',(2080,1240),BG);compare.paste(panels[0],(40,140));compare.paste(panels[1],(1060,140));dr=ImageDraw.Draw(compare)
    text(dr,(40,25),'City region · before / after',40)
    text(dr,(40,91),'Before — original regional terrain',25,MUTED)
    text(dr,(1060,91),'After — approved fit + detailed coast and elevation',25,MUTED)
    text(dr,(40,1142),'White box: model footprint   ·   Teal: exact approved mapping   ·   Amber: deformation ends',23)
    text(dr,(40,1190),'Same position, orientation, scale and height colors in both panels. No terrain was changed to create these images.',21,MUTED)
    compare.save(OUT/'city-before-after.png')
    # Export the local views for a draggable comparison without recomputing.
    panels[0].save(OUT/'city-before.png');panels[1].save(OUT/'city-after.png')
    source=mapping.source_country(mapping.world_to_model(x,z))
    weight=1-smooth(city['inner_radius'],city['outer_radius'],np.hypot(x-center[0],z-center[1]))
    delta=(source-np.stack([x,z],axis=-1))*weight[...,None]
    magnitude=np.linalg.norm(delta,axis=-1)
    vmax=float(magnitude.max())
    colors=np.array([[18,35,43],[34,97,123],[57,156,152],[178,193,128],[255,209,132]])
    rgb=np.stack([np.interp(magnitude/vmax,np.linspace(0,1,len(colors)),colors[:,c]) for c in range(3)],axis=-1).astype(np.uint8)
    im=Image.fromarray(rgb);dr=ImageDraw.Draw(im)
    view.circle(dr,*center,city['inner_radius'],TEAL,2);view.circle(dr,*center,city['outer_radius'],ACCENT,2)
    figure=Image.new('RGB',(1100,1220),BG);figure.paste(im,(60,115));dr=ImageDraw.Draw(figure)
    text(dr,(60,24),'Horizontal adjustment',36)
    text(dr,(60,73),'Terrain sampling displacement · terrain units',23,MUTED)
    gradient=np.linspace(0,1,800)
    strip=np.stack([np.interp(gradient,np.linspace(0,1,len(colors)),colors[:,c]) for c in range(3)],axis=-1).astype(np.uint8)
    figure.paste(Image.fromarray(np.repeat(strip[None,:,:],20,axis=0)),(150,1120))
    text(dr,(150,1150),'0',22);text(dr,(880,1150),f'{vmax:.0f}',22)
    figure.save(OUT/'horizontal-adjustment.png')
    metrics={'base_tiles':(meta['tile_bounds'][2]-meta['tile_bounds'][0])*(meta['tile_bounds'][3]-meta['tile_bounds'][1]),'override_tiles':len(meta['tile_overrides']),'exact_fit_radius_terrain_units':city['inner_radius'],'blend_end_radius_terrain_units':city['outer_radius'],'maximum_inverse_horizontal_displacement_terrain_units':vmax,'view':'Actual XZ game-space terrain, rigidly rotated toward north; not reprojected back onto an undeformed geographic map.','comparison':'Before/after includes horizontal registration, higher-resolution DEM, vector coast, and local support under model geometry.'}
    (OUT/'overview-info.json').write_text(json.dumps(metrics,indent=2)+'\n')
    print('Saved overview and comparison:',OUT,flush=True)


if __name__=='__main__':main()
