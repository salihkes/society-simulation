"""Exact geographic mapping of a user-positioned orthographic model image.

No landmark fitting: the saved picture transform is the alignment authority.
World placement stays rigid at scale one; terrain sampling absorbs the scale.
"""
import math
import numpy as np


class OverlayMapping:
    def __init__(self, accepted, projection):
        self.accepted, self.projection = accepted, projection
        frame, self.pose = accepted['frame'], accepted['pose']
        self.radius = float(frame['earth_radius'])
        self.low = self.mercator(np.array(frame['northwest_lonlat']))
        high = self.mercator(np.array(frame['southeast_lonlat']))
        size = np.array(frame['viewport_size'],float)
        span = high-self.low
        self.pixels_per_mercator = float(np.min((size-2*frame['padding'])/span))
        self.offset = size/2-span*self.pixels_per_mercator/2
        angle = math.radians(self.pose['rotation'])
        self.image_rotation = np.array([[math.cos(angle),math.sin(angle)],[-math.sin(angle),math.cos(angle)]])
        self.mercator_origin = self.low+(np.array([self.pose['x'],self.pose['y']])-self.offset)/self.pixels_per_mercator
        self.mercator_per_model = self.pose['scale']/self.pixels_per_mercator
        self.origin = self.source_country(np.zeros(2))
        jacobian = np.stack([self.source_country([1.,0.])-self.origin,self.source_country([0.,1.])-self.origin])
        u,s,vh = np.linalg.svd(jacobian)
        self.rotation = u@vh
        if np.linalg.det(self.rotation)<0:
            raise ValueError('Overlay would mirror the source model')
        self.source_scales=s
        self.source_area_scale=float(np.sqrt(np.linalg.det(jacobian)))

    def mercator(self,ll):
        ll=np.asarray(ll,float)
        return np.stack([self.radius*np.radians(ll[...,0]),-self.radius*np.log(np.tan(np.pi/4+np.radians(ll[...,1])/2))],axis=-1)

    def inverse_mercator(self,q):
        q=np.asarray(q,float)
        return np.stack([np.degrees(q[...,0]/self.radius),np.degrees(2*np.arctan(np.exp(-q[...,1]/self.radius))-np.pi/2)],axis=-1)

    def model_lonlat(self,model):
        q=self.mercator_origin+np.asarray(model)@self.image_rotation*self.mercator_per_model
        return self.inverse_mercator(q)

    def source_country(self,model):
        ll=self.model_lonlat(model)
        return np.stack(self.projection.from_lonlat(ll[...,0],ll[...,1]),axis=-1)

    def model_to_world(self,model):
        return np.asarray(model)@self.rotation+self.origin

    def world_to_model(self,x,z):
        return np.stack([x-self.origin[0],z-self.origin[1]],axis=-1)@self.rotation.T

    def world_to_lonlat(self,x,z):
        return self.model_lonlat(self.world_to_model(x,z))
