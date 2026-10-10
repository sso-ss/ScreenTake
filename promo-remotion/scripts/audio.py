"""Original 108 BPM instrumental bed and synchronized effects. No sampled music."""
from pathlib import Path
import numpy as np
import wave

root=Path(__file__).resolve().parents[1]
sr=48000
duration=48
beat=60/108
rng=np.random.default_rng(23)
bus=np.zeros((duration*sr,2),dtype=np.float64)
def hz(note): return 440*2**((note-69)/12)
def add(at,y,gain=.1,pan=0):
    start=int(at*sr)
    if start<0: y=y[-start:];start=0
    n=min(len(y),len(bus)-start)
    if n<=0:return
    if y.ndim==1:y=np.column_stack((y,y))
    bus[start:start+n]+=y[:n]*gain*np.array([np.cos((pan+1)*np.pi/4),np.sin((pan+1)*np.pi/4)])
def tone(note,d,kind='pluck'):
    t=np.arange(int(d*sr))/sr
    f=hz(note)
    if kind=='pad':
        y=np.column_stack([sum(np.sin(2*np.pi*f*(1+detune)*i*t)/i**1.8 for i in range(1,5)) for detune in [-.0015,.0015]])
        env=np.minimum(1,t/.45)*np.minimum(1,(d-t)/.65)
        return y*env[:,None]
    y=np.sin(2*np.pi*f*t)+.21*np.sin(2*np.pi*2*f*t)+.07*np.sin(2*np.pi*3*f*t)
    return y*np.exp(-t/(.18 if kind=='pluck' else .48))*np.minimum(1,t/.006)*np.minimum(1,(d-t)/.03)
def kick():
    t=np.arange(int(.35*sr))/sr
    f=42+70*np.exp(-t/.027)
    return np.sin(2*np.pi*np.cumsum(f)/sr)*np.exp(-t/.11)
def tick():
    t=np.arange(int(.05*sr))/sr
    return (rng.normal(0,1,len(t))*.15+np.sin(2*np.pi*1900*t)*.8)*np.exp(-t/.007)*np.minimum(1,t/.001)
chords=[[45,57,60,64],[41,57,60,65],[48,55,60,64],[43,55,59,62]]
bar=beat*4
for b,at in enumerate(np.arange(0,44,bar)):
    notes=chords[b%4]
    for note in notes[1:]:add(at,tone(note,bar+.8,'pad'),.115)
    add(at,tone(notes[0],bar,'bass'),.10)
for i,at in enumerate(np.arange(4,44,beat)):
    add(at,kick(),.24 if at<39 else .14)
    if i%2: add(at,tick(),.08)
    chord=chords[int(at/bar)%4]
    if at<39:
        add(at+beat/2,tone(chord[1+(i%3)]+12,.65),.10,pan=(-.3 if i%2 else .3))
for at in [6.1,9.9,11.5,16.6,21.5,23.0,27.4,30.6,33.5,35.1,37.1,39.7]:add(at,tick(),.13)
for at in [1.35,4,8,19,26,33,39,44]:
    d=.5;t=np.arange(int(d*sr))/sr
    noise=rng.normal(0,1,len(t))
    noise=np.convolve(noise,np.ones(15)/15,mode='same')
    add(at-.22,noise*np.sin(np.pi*t/d)**2,.095,pan=.15)
for n in [48,55,60,64,67]:add(44,tone(n,3.8,'pad'),.15)
for i,n in enumerate([76,79,84]):add(44.2+i*.08,tone(n,1.7),.11,pan=(i-1)*.2)
bus[:int(.35*sr)]*=np.linspace(0,1,int(.35*sr))[:,None]
bus[-int(1.0*sr):]*=np.linspace(1,0,int(1.0*sr))[:,None]
bus=np.tanh(bus*1.4)
bus=bus/max(.01,np.abs(bus).max())*.82
out=root/'public/audio/score.wav'
out.parent.mkdir(exist_ok=True,parents=True)
with wave.open(str(out),'wb') as f:
    f.setnchannels(2);f.setsampwidth(2);f.setframerate(sr);f.writeframes((bus*32767).astype('<i2').tobytes())
print('Original stereo score: 48 seconds, 108 BPM, 48 kHz.')
