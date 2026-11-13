from common import *
W,H=390,844
b=[f'<div class="a" style="inset:0;background:radial-gradient(90% 50% at 50% 30%,rgba({TEAL},.38),transparent 70%),radial-gradient(80% 40% at 50% 100%,rgba(255,150,90,.16),transparent 70%),#05070a"></div>',
   f'<div class="cap" style="left:16px;top:14px"><b>01 · Folded, outer screen</b> · 390×844 pt · assumed size</div>',
   f'<div class="flag" style="right:16px;top:30px;max-width:230px;text-align:right">Reskin needs owner yes - iPhone path is byte-identical by rule</div>',
   # header
   f'<div class="btn" style="left:16px;top:80px;width:44px;height:44px;background:#11151c">{I_down(20)}</div>',
   f'<div class="a" style="left:72px;top:80px;width:246px;height:44px;text-align:center"><div class="lbl" style="color:rgb({TEAL})">Station</div><div style="font-weight:800;font-size:17px;margin-top:3px">Morning Calm</div></div>',
   f'<div class="btn" style="right:16px;top:80px;width:44px;height:44px;background:#11151c">{I_more(20)}</div>',
   art_tidewater(330,330,28,"left:30px;top:136px"),
   # title row with idle ember
   f'<div class="a" style="left:24px;top:484px;width:342px;display:flex;justify-content:space-between;align-items:flex-start">'
   f'<div><div style="font-weight:800;font-size:34px;letter-spacing:-.035em;line-height:1.02">Tidewater</div>'
   f'<div style="font-weight:600;font-size:15px;color:rgba(255,255,255,.72);margin-top:6px">Lumen Harbor</div></div>'
   f'<div style="display:flex;align-items:center;gap:8px;margin-top:10px;height:28px;padding:0 10px;border-radius:14px;background:#11151c">{orb("idle",12)}<span class="lbl" style="font-size:9px;color:rgba(255,255,255,.62)">Mic down</span></div></div>',
   # scrubber
   f'<div class="a" style="left:24px;top:560px;width:342px;height:44px">'
   f'<div class="a" style="left:0;top:16px;width:342px;height:6px;border-radius:3px;background:rgba(255,255,255,.18)"></div>'
   f'<div class="a" style="left:0;top:16px;width:116px;height:6px;border-radius:3px;background:#fff"></div>'
   f'<div class="a" style="left:108px;top:11px;width:16px;height:16px;border-radius:50%;background:#fff"></div>'
   f'<div class="a" style="left:0;top:30px;font-size:11px;font-weight:700;color:rgba(255,255,255,.7)">1:12</div>'
   f'<div class="a" style="right:0;top:30px;font-size:11px;font-weight:700;color:rgba(255,255,255,.7)">−2:28</div></div>',
   # transport glass
   f'<div class="glass" style="left:24px;top:614px;width:342px;height:80px;border-radius:40px">'
   f'<div class="btn" style="left:40px;top:18px;width:44px;height:44px">{I_prev(28)}</div>'
   f'<div class="btn" style="left:139px;top:8px;width:64px;height:64px;background:#fff;box-shadow:0 0 0 6px rgba({TEAL},.25)">{I_pause(28,"#071512")}</div>'
   f'<div class="btn" style="left:258px;top:18px;width:44px;height:44px">{I_next(28)}</div></div>',
   # up next, solid
   f'<div class="solid" style="left:24px;top:706px;width:342px;height:44px;border-radius:22px;display:flex;align-items:center;gap:10px;padding:0 8px">'
   f'{art_small(30,"satellites",15)}<span class="lbl" style="font-size:9px">Next</span><span style="font-weight:800;font-size:13px">Paper Satellites</span>'
   f'<span style="font-weight:600;font-size:12px;color:rgba(255,255,255,.6)">Velvet Orchard</span></div>',
]
tabs=[(I_wave(22),"Now Playing",True),(I_radio(22),"Stations",False),(I_stack(22),"Library",False),(I_gear(22),"Settings",False)]
t="".join(f'<div style="width:78px;height:52px;border-radius:26px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;{"background:rgba(255,255,255,.16)" if a else ""}">{i}<span style="font-size:9.5px;font-weight:700;color:{"#fff" if a else "rgba(255,255,255,.75)"}">{n}</span></div>' for i,n,a in tabs)
b.append(f'<div class="glass" style="left:24px;top:764px;width:342px;height:60px;border-radius:30px;display:flex;align-items:center;justify-content:space-around;padding:0 4px">{t}</div>')
page("01-folded",W,H,"".join(b))
