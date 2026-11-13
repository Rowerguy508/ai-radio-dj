H='<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="base.css"></head><body>'
def page(name,w,h,inner,cap):
    open(f"{name}.html","w").write(H+f'<div class="cap">{cap}</div><div class="dev" style="width:{w}px;height:{h}px">{inner}</div></body></html>')
def T(x,y,txt,cls="",w=None,extra=""):
    ws=f"width:{w}px;" if w else ""
    return f'<div class="t {cls}" style="left:{x}px;top:{y}px;{ws}{extra}">{txt}</div>'
def B(x,y,w,h,txt,extra=""): return f'<div class="btn" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;{extra}">{txt}</div>'
def P(x,y,w,h,txt="artwork",r=20): return f'<div class="ph" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:{r}px">{txt}</div>'
def BX(x,y,w,h,inner="",r=14,extra=""): return f'<div class="box" style="left:{x}px;top:{y}px;width:{w}px;height:{h}px;border-radius:{r}px;{extra}">{inner}</div>'
def BAR(x,y,w): return f'<div class="bar" style="left:{x}px;top:{y}px;width:{w}px"><i></i></div>'
def N(x,y,txt,w=300,c="#b03"): return f'<div class="note" style="left:{x}px;top:{y}px;width:{w}px;color:{c}">{txt}</div>'

# 1 Folded (compact) 390x844 - size assumed
f=[T(16,60,"⌄",""),T(140,58,"Morning Mix","b",110,"text-align:center"),T(350,56,"⋯","b"),
   P(32,110,326,326),T(24,460,"Morning Light","b",342,"font-size:20px"),T(24,488,"Artist Name","s",342),
   B(24,516,150,30,"DJ · Ready"),BAR(24,570,342),T(24,582,"1:12","s"),T(336,582,"3:40","s"),
   B(70,620,52,52,"⏮"),B(165,610,64,64,"▶︎","font-size:20px"),B(270,620,52,52,"⏭"),
   B(24,700,342,44,"Up next · Silver Coast  ›"),
   N(16,770,"FOLDED SIZE NOT MEASURED ON THE DUO.<br>Drawn at 390×844 (iPhone 16e, our compact test size). Unchanged from today.",360)]
page("1-folded",390,844,"".join(f),"1 · Folded (compact player) · 390×844 pt ASSUMED")

# 2 Unfolded horizontal 640x820 measured
L=8;R=326;PW=306
u=[BX(L,8,PW,804,"",30,"background:#fafaf8"),BX(R,8,PW,804,"",30,"background:#fafaf8"),
   f'<div class="hinge" style="left:319px;top:0;width:2px;height:820px"></div>',
   T(24,62,"Morning Mix","b"),T(270,60,"⋯","b"),
   P(24,96,274,274),T(24,388,"Morning Light","b",274,"font-size:22px"),T(24,418,"Artist Name","s",274),
   B(24,446,140,30,"DJ · Ready"),
   T(24,500,"DJ line (up to 3 lines, from<br>DJStatusPresentation.headline)","s",274),
   N(24,700,"LEFT HALF: art + title stay here.<br>Nothing below this fold moves on fold/unfold.",270),
   # right
   BX(R+12,54,PW-24,150,"",22),BAR(R+28,74,PW-56),T(R+28,86,"1:12","s"),T(R+PW-60,86,"3:40","s"),
   B(R+48,118,52,52,"⏮"),B(R+PW/2-32,110,64,64,"▶︎","font-size:20px"),B(R+PW-100,118,52,52,"⏭"),
   T(R+28,180,"Station · Morning Mix","s"),
   BX(R+12,218,PW-24,300,"",22),T(R+28,230,"Up next","b"),
   T(R+28,262,"● Morning Light — now","",250),T(R+28,292,"○ Silver Coast","",250),
   T(R+28,322,"◆ DJ break (headline only)","",250,"color:#555"),T(R+28,352,"○ Low Tide","",250),T(R+28,382,"○ Paper Boats","",250),
   T(R+28,420,"#464 timeline. Break line reads only<br>DJStatusPresentation.headline in .ready.","s",260),
   BX(R+12,532,PW-24,190,"",22),T(R+28,544,"Tuner","b"),
   B(R+24,576,80,40,"Jazz"),B(R+112,572,90,48,"<b>Indie</b>","border-width:3px"),B(R+210,576,80,40,"Lo‑fi"),
   B(R+PW/2-50,630,100,40,"Tune"),
   T(R+28,680,"#463 dial: swipe moves highlight; tap or Tune opens.","s",270),
   BX(R+12,738,PW-24,60,"",30),B(R+28,746,44,44,"‹"),B(R+96,746,44,44,"⋯"),B(R+164,746,44,44,"☰"),B(R+232,746,44,44,"◎"),
  ]
page("2-unfolded",640,820,"".join(u),"2 · Unfolded, horizontal · 640×820 pt (measured, owner build 44). Right half filled: transport, up next, tuner, symbol bar")

# 3 Tent pose 820x640 landscape, two 320 halves; assumption
t=[f'<div class="hinge" style="left:0;top:319px;width:820px;height:2px"></div>',
   BX(8,8,804,304,"",30),P(32,28,264,264),T(320,48,"Morning Light","b",460,"font-size:30px"),T(320,92,"Artist Name","s",460,"font-size:16px"),
   B(320,140,150,34,"DJ · On Air"),B(500,200,88,88,"▶︎","font-size:28px"),B(410,216,56,56,"⏮"),B(620,216,56,56,"⏭"),
   f'<div style="position:absolute;left:0;top:321px;width:820px;height:319px;background:#d8d8d4"></div>',
   T(250,450,"Back half faces away: dark, no content, no touch.","s",400,"text-align:center"),
   N(24,560,"ASSUMPTIONS: tent = unfolded landscape, folded ~90°, hinge horizontal. The SDK API for pose/hinge is NOT YET CONFIRMED on the 27.1 runner; if it isn't there this frame is dropped, not faked.",770)]
page("3-tent",820,640,"".join(t),"3 · Tent pose · 820×640 pt ASSUMED (unfolded, rotated)")

# 4 StandBy 844x390 folded landscape
s=[f'<div style="position:absolute;inset:0;background:#111"></div>',
   BX(16,16,400,358,"",30,"background:#222;border-color:#444"),P(40,40,150,150,"art",18),
   T(210,48,"Morning Light","b",190,"color:#eee;font-size:22px"),T(210,104,"Artist Name","",190,"color:#aaa"),
   B(210,150,130,32,"On Air","background:#222;color:#f66;border-color:#f66"),
   B(170,250,80,80,"▶︎","background:#333;color:#eee;font-size:26px;border-color:#666"),
   BX(428,16,400,358,"",30,"background:#222;border-color:#444"),T(452,40,"AeroDJ · Morning Mix","b",360,"color:#eee"),
   T(452,80,"Up next: Silver Coast","",360,"color:#aaa"),T(452,110,"Next DJ break after this track","",360,"color:#aaa"),
   N(452,200,"Widgets read the App Group: title, artist, art, state ONLY. No tokens, user ID, consent state, tester_voice. No script or briefing text. 'On Air' only from confirmed .speaking (DJStudioState.onAirLabel).",360,"#ffd479")]
page("4-standby",844,390,"".join(s),"4 · StandBy (charging, landscape) · 844×390 pt ASSUMED (folded rotated)")

# 5 Live Activity lock screen 390x844
la=[f'<div style="position:absolute;inset:0;background:linear-gradient(#5a6b7c,#2b3440)"></div>',
    T(0,90,"Thu 12 Nov","",390,"color:#eee;text-align:center"),T(0,112,"9:41","b",390,"color:#fff;text-align:center;font-size:72px"),
    BX(16,520,358,150,"",22,"background:rgba(30,30,30,.85);border-color:#999"),P(30,536,72,72,"art",12),
    T(116,540,"██████ ███","b",180,"color:#ddd"),T(116,564,"███ ████","",180,"color:#999"),
    B(116,590,110,28,"DJ · Ready","background:transparent;color:#ddd;border-color:#888"),
    B(300,550,56,56,"▶︎","background:#444;color:#fff;border-color:#888"),BAR(30,638,328),
    T(16,680,"Default: title/artist redacted (privacySensitive) while locked. Unlocked, it shows the real title and artist.","",358,"color:#eee;font-size:12px"),
    N(16,740,"Live Activity reads published state only; it never drives or delays DJ playback. 'On Air' only on confirmed .speaking. Max height 160 pt.",358,"#ffd479")]
page("5-liveactivity",390,844,"".join(la),"5 · Live Activity on the lock screen · 390×844 pt ASSUMED")
