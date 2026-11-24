"""Offline pocket-phone activity and floor estimation with building calibration."""
import argparse,json
from pathlib import Path
import numpy as np
import pandas as pd
from scipy.signal import butter,sosfiltfilt
from scipy.ndimage import median_filter
from scipy.cluster.vq import kmeans2
from scipy.stats import theilslopes
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

NAMES=["stationary","walking","stairs_up","stairs_down","elevator"]

def load(folder):
    folder=Path(folder)
    m=pd.read_csv(folder/"motion.csv",dtype={"time":"int64"}).sort_values("time").drop_duplicates("time")
    b=pd.read_csv(folder/"barometer.csv",dtype={"time":"int64"}).sort_values("time").drop_duplicates("time")
    origin=int(m.time.iloc[0])
    mt=(m.time.to_numpy()-origin)/1e9
    bt=(b.time.to_numpy()-origin)/1e9
    a=m[["acc_x","acc_y","acc_z"]].to_numpy()
    g=m[["grav_x","grav_y","grav_z"]].to_numpy()
    v=(a*g).sum(axis=1)/np.linalg.norm(g,axis=1)
    h=b.rel_alt_m.to_numpy()
    if len(mt)<100 or len(bt)<20 or not np.all(np.isfinite(v)) or not np.all(np.isfinite(h)):
        raise ValueError("Insufficient or invalid sensor values.")
    if np.max(np.diff(mt))>.5 or np.max(np.diff(bt))>1:
        raise ValueError("Long sensor gap: split the recording before analysis.")
    start,end=max(mt[0],bt[0]),min(mt[-1],bt[-1])
    t=np.arange(start,end,.5)
    if len(t)<20: raise ValueError("Recording must overlap for at least 10 seconds.")
    height=median_filter(np.interp(t,bt,h),size=5,mode="nearest")
    grid=np.arange(start,end,.02)
    signal=np.interp(grid,mt,v)
    signal=sosfiltfilt(butter(3,[.5,8],btype="bandpass",fs=50,output="sos"),signal)
    energy=np.array([np.std(signal[(grid>=x-1.5)&(grid<=x+1.5)]) for x in t])
    slope=np.array([theilslopes(height[max(0,i-6):i+7],t[max(0,i-6):i+7])[0] for i in range(len(t))])
    return t,height,energy,slope,origin

def calibrate(folders,path):
    profiles=[]
    details=[]
    for folder in folders:
        t,h,e,s,origin=load(folder)
        stable=h[np.abs(s)<.08]
        if len(stable)<24: raise ValueError("Too few stable samples for six-floor calibration.")
        initial=np.linspace(np.quantile(stable,.03),np.quantile(stable,.97),6)
        centers,_=kmeans2(stable,initial,minit="matrix")
        centers=np.sort(centers)
        assignments=np.argmin(abs(stable[:,None]-centers),axis=1)
        centers=np.array([np.median(stable[assignments==i]) for i in range(6)])
        if not np.all(np.isfinite(centers)) or np.any(np.diff(centers)<2):
            raise ValueError("Calibration did not find six separated floor levels.")
        profile=centers-centers[0]
        profiles.append(profile)
        details.append(dict(folder=str(folder),levels_m=centers.tolist()))
    heights=np.median(profiles,axis=0)
    model=dict(floors=list(range(1,7)),relative_heights_m=heights.tolist(),
               calibration_recordings=details,assumption="Each calibration recording visits floors 1 through 6 in order.")
    Path(path).write_text(json.dumps(model,indent=2),encoding="utf-8")
    print(json.dumps(model,indent=2))

def runs(labels):
    bounds=np.r_[0,np.flatnonzero(labels[1:]!=labels[:-1])+1,len(labels)]
    return list(zip(bounds[:-1],bounds[1:]))

def analyze(folder,model_path,start_floor,out):
    model=json.loads(Path(model_path).read_text())
    floors=np.array(model["floors"]); levels=np.array(model["relative_heights_m"])
    if start_floor not in floors: raise ValueError("Start floor is outside calibrated floors.")
    t,h,e,s,origin=load(folder)
    # First five seconds must be on the supplied start floor.
    reference=np.median(h[t<t[0]+5])
    absolute=h-reference+levels[np.where(floors==start_floor)[0][0]]
    labels=np.where(e<.6,0,1)
    labels[(e>=.6)&(s>.10)]=2
    labels[(e>=.6)&(s<-.10)]=3
    labels[(e<.6)&(abs(s)>.15)]=4
    # Eliminate sub-1.5 s spikes with a majority vote over the original labels.
    original=labels.copy()
    for i in range(len(labels)):
        votes=np.bincount(original[max(0,i-1):i+2],minlength=5)
        labels[i]=np.argmax(votes)
    # Reject short vertical-motion spikes before joining same-direction flights.
    for left,right in runs(labels.copy()):
        if labels[left] in [2,3,4] and (right-left)*.5<3:
            labels[left:right]=np.where(e[left:right]<.6,0,1)
    # A brief landing between stair flights retains the enclosing stair activity.
    for left,right in runs(labels.copy()):
        if left==0 or right==len(labels): continue
        if (right-left)*.5<=6 and labels[left] in [0,1] and labels[left-1]==labels[right] and labels[right] in [2,3]:
            labels[left:right]=labels[right]
    index=int(np.where(floors==start_floor)[0][0])
    current=[]; pending=None; held=0
    for value in absolute:
        candidate=int(np.argmin(abs(levels-value)))
        if candidate!=index and abs(value-levels[candidate])<.75:
            if candidate==pending: held+=1
            else: pending=candidate; held=1
            if held>=4: index=candidate; pending=None; held=0
        else: pending=None; held=0
        current.append(int(floors[index]))
    nearest=floors[np.argmin(abs(absolute[:,None]-levels),axis=1)]
    state=np.where(abs(s)>.10,"moving_vertical","level")
    low=(abs(e-.6)<.2)|(abs(abs(s)-.10)<.04)
    frame=pd.DataFrame(dict(time_s=t,activity=[NAMES[x] for x in labels],floor=current,
        nearest_floor=nearest,vertical_state=state,height_m=absolute,height_slope_m_s=s,
        acceleration_std=e,low_margin=low,
        elevator_direction=np.where(labels==4,np.where(s>0,"up","down"),"")))
    out=Path(out);out.mkdir(parents=True,exist_ok=True)
    frame.to_csv(out/"timeline.csv",index=False)
    segments=[dict(start_s=float(t[l]),end_s=float(min(t[r-1]+.5,t[-1]+.5)),activity=NAMES[labels[l]]) for l,r in runs(labels)]
    pd.DataFrame(segments).to_csv(out/"activities.csv",index=False)
    changed=frame.floor.ne(frame.floor.shift())
    frame.loc[changed,["time_s","floor"]].to_csv(out/"floor_events.csv",index=False)
    summary=dict(origin_epoch_ns=origin,start_floor=start_floor,final_floor=current[-1],
                 reference_height_m=float(reference),offline=True,
                 note="Uses future samples; floors are hysteretic height estimates, not arrival ground truth.")
    (out/"summary.json").write_text(json.dumps(summary,indent=2),encoding="utf-8")
    fig,axes=plt.subplots(3,1,sharex=True,figsize=(13,8),layout="constrained")
    axes[0].plot(t,absolute);axes[0].set_ylabel("Height (m)")
    for level in levels: axes[0].axhline(level,color="grey",alpha=.25)
    axes[1].step(t,current,where="post");axes[1].set_yticks(floors);axes[1].set_ylabel("Estimated floor")
    axes[2].step(t,labels,where="post");axes[2].set_yticks(range(5),NAMES);axes[2].set_xlabel("Time (s)")
    for ax in axes: ax.grid(alpha=.2)
    fig.savefig(out/"overview.png",dpi=150);plt.close(fig)
    print(folder,"final floor",current[-1])

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    commands=parser.add_subparsers(dest="command",required=True)
    c=commands.add_parser("calibrate");c.add_argument("folders",nargs="+");c.add_argument("--model",default="building.json")
    a=commands.add_parser("analyze");a.add_argument("folder");a.add_argument("--model",default="building.json")
    a.add_argument("--start-floor",required=True,type=int);a.add_argument("--out",default="results")
    args=parser.parse_args()
    if args.command=="calibrate": calibrate(args.folders,args.model)
    else: analyze(args.folder,args.model,args.start_floor,args.out)
if __name__=="__main__": main()
