from common import *
W,H=820,640
b=[f'<div class="a" style="left:0;top:0;width:820px;height:306px;background:radial-gradient(50% 90% at 14% 55%,rgba(255,59,47,.36),transparent 70%),radial-gradient(50% 90% at 88% 40%,rgba({TEAL},.30),transparent 70%),#05070a"></div>',
   '<div class="a" style="left:0;top:306px;width:820px;height:28px;background:linear-gradient(180deg,#05070a,#000 50%,#020304)"></div>',
   '<div class="a" style="left:0;top:319.5px;width:820px;height:1px;background:rgba(255,255,255,.10)"></div>',
   '<div class="a" style="left:0;top:334px;width:820px;height:306px;background:#020304"></div>',
   f'<div class="cap" style="left:20px;top:14px"><b>03 · Tent pose · radio face</b> · 820×640 pt · assumed size (unfolded, rotated)</div>',
   f'<div class="flag" style="right:20px;top:10px">Pose API unconfirmed in 27.1 SDK</div>',
   # orb + tally
   f'<div class="a" style="left:70px;top:70px">{orb("speaking",140)}</div>',
   f'<div class="a" style="left:88px;top:240px"><span class="tally"><i></i>ON AIR</span></div>',
   # clock
   f'<div class="a" style="left:268px;top:52px;font-weight:800;font-size:150px;line-height:1;letter-spacing:-.06em">9:41</div>',
   f'<div class="a" style="left:276px;top:214px;font-weight:700;font-size:15px;letter-spacing:.02em;color:rgba(255,255,255,.7)">Thursday · 12 November</div>',
   # station + track
   f'<div class="a" style="left:600px;top:76px;width:200px"><div class="lbl" style="color:rgb({TEAL})">Station</div>'
   f'<div style="font-weight:800;font-size:34px;line-height:.98;letter-spacing:-.035em;margin-top:6px">Morning<br>Calm</div>'
   f'<div style="margin-top:16px" class="lbl">Up after the break</div>'
   f'<div style="font-weight:800;font-size:16px;margin-top:5px">Paper Satellites</div>'
   f'<div style="font-weight:600;font-size:13px;color:rgba(255,255,255,.7);margin-top:2px">Velvet Orchard</div></div>',
   # tap hint
   f'<div class="a" style="left:600px;top:252px;height:30px;padding:0 14px;border-radius:15px;border:1px solid rgba(255,255,255,.28);display:flex;align-items:center;font-size:11.5px;font-weight:700;color:rgba(255,255,255,.8)">Tap to show controls</div>',
   # back half
   f'<div class="a" style="left:0;top:380px;width:820px;text-align:center"><div class="lbl" style="color:rgba(255,255,255,.55)">Back half faces away</div>'
   f'<div style="margin-top:8px;font-size:13px;font-weight:600;color:rgba(255,255,255,.5)">The display is off here and takes no touch. Every control stays hidden until the face is tapped.</div></div>',
   f'<div class="ann" style="left:40px;top:470px;width:740px;padding-top:10px;border-top:1px solid rgba(255,255,255,.12);font-size:9.5px">'
   f'<span class="k">STATE</span>Shown in DJ speaking. In ready it shows the breathing ring, with no tally. In idle it shows the ember, and the clock keeps the face. '
   f'<span class="k">MOTION</span>Nothing loops while idle. Tapping fades the glass transport up over about 250 ms, and it hides again after 5 s with no touch. '
   f'<span class="k">A11Y</span>Reduce Motion gives a crossfade, and Reduce Transparency gives solid controls. '
   f'<span class="k">SDK</span>The tent layout ships only if the iOS 27.1 SDK exposes a pose or hinge API (#465 items 2 and 3). Otherwise this frame is dropped, not faked.</div>',
   f'<div class="a" style="left:330px;top:548px;width:160px;height:72px"><svg width="160" height="72" viewBox="0 0 160 72" fill="none" stroke-linecap="round">'
   f'<path d="M30 66 L80 10 L130 66" stroke="rgba(255,255,255,.35)" stroke-width="3"/><path d="M30 66 L80 10" stroke="rgb({TEAL})" stroke-width="5"/>'
   f'<circle cx="80" cy="10" r="4" fill="#fff"/><text x="0" y="40" font-family="Inter" font-size="9" font-weight="800" fill="rgb({TEAL})">FACE</text>'
   f'<text x="128" y="40" font-family="Inter" font-size="9" font-weight="800" fill="rgba(255,255,255,.45)">BACK</text></svg></div>',
]
page("03-tent",W,H,"".join(b))
