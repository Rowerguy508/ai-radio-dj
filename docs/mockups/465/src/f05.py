from common import *
W,H=390,844
FL=svg('<path d="M9 3h6l-1 6h-4zM10 9h4v12h-4z"/>',20)
CAM=svg('<rect x="3" y="7" width="18" height="13" rx="3"/><circle cx="12" cy="13.5" r="3.5"/><path d="M9 7l1.5-2.5h3L15 7"/>',20)
b=[f'<div class="a" style="inset:0;background:radial-gradient(120% 60% at 20% 10%,rgba({TEAL},.55),transparent 60%),radial-gradient(100% 50% at 90% 60%,rgba(255,140,90,.35),transparent 60%),linear-gradient(#0a2a30,#0a0d14 70%)"></div>',
   # dynamic island (compact, live)
   f'<div class="a" style="left:120px;top:11px;width:150px;height:37px;border-radius:19px;background:#000;display:flex;align-items:center;justify-content:space-between;padding:0 12px"></div>',
   f'<div class="cap" style="left:16px;top:58px"><b>05 · Lock screen + Live Activity</b> · 390×844 pt · assumed size</div>',
   f'<div class="a" style="left:0;top:86px;width:390px;text-align:center;font-weight:700;font-size:17px;color:rgba(255,255,255,.85)">Thursday 12 November</div>',
   f'<div class="a" style="left:0;top:104px;width:390px;text-align:center;font-weight:800;font-size:96px;letter-spacing:-.05em;line-height:1.05">9:41</div>',
   # specimen callouts
   f'<div class="a" style="left:16px;top:236px;width:358px;height:282px;border-radius:28px;background:rgba(0,0,0,.32);border:1px dashed rgba(255,255,255,.25)"></div>',
   f'<div class="a" style="left:32px;top:250px" class="lbl"><span class="lbl" style="color:rgba(255,255,255,.85)">Dynamic Island · specimens</span></div>',
   f'<div class="a" style="left:32px;top:276px;font-size:10.5px;font-weight:700;color:rgba(255,255,255,.7)">Compact: station-colour dot and tally</div>',
   f'<div class="a" style="left:32px;top:296px;width:180px;height:37px;border-radius:19px;background:#000;display:flex;align-items:center;justify-content:space-between;padding:0 13px">'
   f'<div style="display:flex;align-items:center;gap:7px"><div style="width:14px;height:14px;border-radius:50%;background:rgb({TEAL})"></div></div>'
   f'<div style="display:flex;align-items:center;gap:6px"><div style="width:12px;height:12px;border-radius:50%;background:{RED};box-shadow:0 0 8px {RED}"></div></div></div>',
   f'<div class="a" style="left:226px;top:300px;width:136px;font-size:9.5px;line-height:1.35;font-weight:600;color:rgba(255,255,255,.62)">Tally only on a confirmed .speaking.</div>',
   f'<div class="a" style="left:32px;top:346px;font-size:10.5px;font-weight:700;color:rgba(255,255,255,.7)">Expanded (unlocked): title, artist, skip</div>',
   f'<div class="a" style="left:32px;top:366px;width:326px;height:138px;border-radius:40px;background:#000;padding:18px 20px">'
   f'<div style="display:flex;align-items:center;gap:12px">{art_tidewater(58,58,14,"position:relative")}'
   f'<div style="flex:1;min-width:0"><div style="font-weight:800;font-size:17px">Tidewater</div><div style="font-weight:600;font-size:13px;color:rgba(255,255,255,.7);margin-top:2px">Lumen Harbor</div></div>'
   f'<div style="width:44px;height:44px;border-radius:22px;background:rgba(255,255,255,.14);display:flex;align-items:center;justify-content:center">{I_next(22)}</div></div>'
   f'<div style="display:flex;align-items:center;justify-content:space-between;margin-top:14px">'
   f'<div style="display:flex;align-items:center;gap:7px"><div style="width:10px;height:10px;border-radius:50%;background:rgb({TEAL})"></div><span style="font-size:12px;font-weight:700;color:rgba(255,255,255,.8)">Morning Calm</span></div>'
   f'<div style="display:flex;align-items:center;gap:6px"><div style="width:10px;height:10px;border-radius:50%;background:{RED};box-shadow:0 0 8px {RED}"></div><span style="font-size:10px;font-weight:800;letter-spacing:.16em;color:#ff8a7f">ON AIR</span></div></div></div>',
   # Live Activity on the lock screen (redacted by default)
   f'<div class="a" style="left:16px;top:540px;width:358px;height:150px;border-radius:28px;background:rgba(14,18,24,.78);-webkit-backdrop-filter:blur(30px);backdrop-filter:blur(30px);border:1px solid rgba(255,255,255,.12);padding:16px">'
   f'<div style="display:flex;align-items:center;justify-content:space-between">'
   f'<div style="display:flex;align-items:center;gap:8px">{onairly_mark(13)}</div>'
   f'<div style="display:flex;align-items:center;gap:7px"><div style="width:11px;height:11px;border-radius:50%;background:{RED};box-shadow:0 0 8px {RED},0 0 20px rgba(255,59,47,.6)"></div><span style="font-size:10px;font-weight:800;letter-spacing:.16em;color:#ff8a7f">ON AIR</span></div></div>'
   f'<div style="display:flex;align-items:center;gap:12px;margin-top:14px">'
   f'<div style="width:64px;height:64px;border-radius:14px;background:rgba(255,255,255,.14);flex:none"></div>'
   f'<div style="flex:1"><span class="redact" style="width:150px;height:18px"></span><br><span class="redact" style="width:100px;height:13px;margin-top:10px"></span></div>'
   f'<div style="width:48px;height:48px;border-radius:24px;background:rgba(255,255,255,.16);display:flex;align-items:center;justify-content:center;flex:none">{I_next(22)}</div></div>'
   f'<div style="display:flex;align-items:center;gap:6px;margin-top:12px;font-size:10px;font-weight:700;color:rgba(255,255,255,.62)">{I_lock(12,"rgba(255,255,255,.62)")}Locked · privacySensitive redaction is on by default</div></div>',
   f'<div class="ann" style="left:16px;top:702px;width:358px;font-size:9px">'
   f'<span class="k">RULES</span>Shows only the station, the track, the on-air dot and skip. No script or briefing text appears anywhere. The Live Activity only reads published state: it never drives or delays DJ playback. The tally lights only on confirmed .speaking. The App Group holds display fields only. Max height 160 pt.</div>',
   # flashlight / camera affordances
   f'<div class="btn" style="left:46px;top:760px;width:50px;height:50px;background:rgba(0,0,0,.35)">{FL}</div>',
   f'<div class="btn" style="right:46px;top:760px;width:50px;height:50px;background:rgba(0,0,0,.35)">{CAM}</div>',
   '<div class="a" style="left:128px;top:830px;width:134px;height:5px;border-radius:3px;background:rgba(255,255,255,.85)"></div>',
]
page("05-live-activity",W,H,"".join(b))
