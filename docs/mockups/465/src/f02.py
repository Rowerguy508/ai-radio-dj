import sys
from common import *
W,H=640,820
# FoldedColumnLayout: edge 16, gutter 28, bar 56, status clearance 56, fold at 320
LX,LW=16,290            # left column 16..306
RX,RW=334,234           # content column 334..568
BX_,BW=568,56           # symbol bar 568..624
def build(variant):
    sp = variant=="speaking"
    b=[]
    # backdrop: station-colour gradients (content layer, no shadows)
    b.append(f'<div class="a" style="inset:0;background:'
             f'radial-gradient(70% 55% at 22% 40%,rgba({TEAL},.34),transparent 70%),'
             f'radial-gradient(60% 45% at 18% 95%,rgba(255,150,90,.20),transparent 70%),'
             + (f'radial-gradient(55% 40% at 78% 16%,rgba(255,59,47,.38),transparent 70%),' if sp else f'radial-gradient(55% 40% at 78% 12%,rgba(255,170,110,.14),transparent 70%),')
             + f'radial-gradient(60% 50% at 80% 80%,rgba({TEAL},.16),transparent 70%),#05070a"></div>')
    # hinge band 306..334 left empty; hairline at the fold
    b.append('<div class="a" style="left:306px;top:0;width:28px;height:820px;background:linear-gradient(90deg,transparent,rgba(0,0,0,.35) 45%,rgba(0,0,0,.35) 55%,transparent)"></div>')
    b.append('<div class="a" style="left:319.5px;top:0;width:1px;height:820px;background:rgba(255,255,255,.07)"></div>')
    # caption (left column only, never crosses the band)
    b.append(f'<div class="cap" style="left:{LX}px;top:16px"><b>02{"" if sp else "b"} · Unfolded · {"DJ speaking" if sp else "DJ ready"}</b> · 640×820 pt · measured</div>')
    # ---- LEFT: station identity + art ----
    b.append(f'<div class="a" style="left:{LX}px;top:58px;display:flex;align-items:center;justify-content:space-between;width:{LW}px">{onairly_mark(14)}'
             f'<span class="lbl" style="color:rgba({TEAL},1)">Station</span></div>')
    b.append(f'<div class="a" style="left:{LX-2}px;top:82px;width:{LW}px;font-weight:800;font-size:56px;line-height:.9;letter-spacing:-.045em">Morning<br><span style="color:rgb({TEAL})">Calm</span></div>')
    artY=196
    scale = "transform:scale(.94);" if sp else ""
    b.append(art_tidewater(LW, LW, 28, f"left:{LX}px;top:{artY}px;{scale}"))
    if sp:
        b.append(f'<div class="ann" style="left:{LX+8}px;top:{artY+LW-4}px;font-size:8px;color:rgba(255,255,255,.55)">art at 0.94 while the DJ speaks</div>')
    # scrubber (solid, content layer)
    sy=artY+LW+12
    b.append(f'<div class="a" style="left:{LX}px;top:{sy}px;width:{LW}px;height:44px">'
             f'<div class="a" style="left:0;top:18px;width:{LW}px;height:6px;border-radius:3px;background:rgba(255,255,255,.18)"></div>'
             f'<div class="a" style="left:0;top:18px;width:{LW*(.96 if sp else .34):.0f}px;height:6px;border-radius:3px;background:#fff"></div>'
             f'<div class="a" style="left:{LW*(.96 if sp else .34)-8:.0f}px;top:13px;width:16px;height:16px;border-radius:50%;background:#fff"></div>'
             f'<div class="a" style="left:0;top:32px;font-size:11px;font-weight:700;color:rgba(255,255,255,.7)">{"3:31" if sp else "1:12"}</div>'
             f'<div class="a" style="right:0;top:32px;font-size:11px;font-weight:700;color:rgba(255,255,255,.7)">{"−0:09" if sp else "−2:28"}</div></div>')
    cy=sy+56
    if sp:
        # live caption = DJStatusPresentation.headline, SAMPLE copy
        b.append(f'<div class="solid" style="left:{LX}px;top:{cy}px;width:{LW}px;height:116px;background:#160c0d;border:1px solid rgba(255,59,47,.35)"></div>')
        b.append(f'<div class="a" style="left:{LX+18}px;top:{cy+16}px;width:{LW-36}px">'
                 f'<div style="display:flex;align-items:center;gap:8px"><span class="lbl" style="color:#ff8a7f">DJ on the mic</span><span class="sample">SAMPLE</span></div>'
                 f'<div style="margin-top:9px;font-weight:700;font-size:16px;line-height:1.32;letter-spacing:-.01em">“That was Lumen Harbor. Fog’s lifting off the water. Here’s something bright to go with it.”</div></div>')
    else:
        b.append(f'<div class="solid" style="left:{LX}px;top:{cy}px;width:{LW}px;height:116px"></div>')
        b.append(f'<div class="a" style="left:{LX+18}px;top:{cy+16}px;width:{LW-36}px">'
                 f'<div class="lbl">Station mood</div>'
                 f'<div style="margin-top:8px;font-weight:700;font-size:16px;line-height:1.32">Slow mornings, warm keys and soft voices, picked from your library.</div></div>')
    ry=cy+128
    b.append(f'<div class="a" style="left:{LX}px;top:{ry}px;width:{LW}px;height:48px;display:flex;align-items:center;gap:10px">'
             f'<div style="width:48px;height:48px;border-radius:24px;background:#11151c;display:flex;align-items:center;justify-content:center">{I_up(20)}</div>'
             f'<div style="width:48px;height:48px;border-radius:24px;background:#11151c;display:flex;align-items:center;justify-content:center">{I_downv(20)}</div>'
             f'<div style="margin-left:6px;font-size:12px;font-weight:600;line-height:1.3;color:rgba(255,255,255,.72)">Rate this song.<br>It tunes the station.</div></div>')
    # ---- RIGHT: studio rail ----
    y=58
    if sp:
        b.append(f'<div class="a" style="left:{RX}px;top:{y}px;width:{RW}px;display:flex;justify-content:space-between;align-items:center">'
                 f'<span class="rail" style="margin-left:2px"><span class="tally"><i></i>ON AIR</span></span><span class="lbl" style="color:#ffb3aa">Live · DJ</span></div>')
        od=132
        b.append(f'<div class="a" style="left:{RX+(RW-od)/2}px;top:{y+50}px">{orb("speaking",od)}</div>')
        y=y+50+od+30
    else:
        b.append(f'<div class="a" style="left:{RX}px;top:{y-4}px;width:{RW}px;display:flex;align-items:center;gap:12px">'
                 f'{orb("ready",44)}<div><div class="lbl" style="color:#ffc9a3">Mic ready</div>'
                 f'<div style="font-size:12px;font-weight:600;color:rgba(255,255,255,.7);margin-top:3px">DJ on this station</div></div></div>')
        y=y+66
    # now playing
    b.append(f'<div class="a" style="left:{RX}px;top:{y}px;width:{RW}px">'
             f'<div class="lbl">{"Up after the break" if sp else "Now playing"}</div>'
             f'<div style="margin-top:6px;font-weight:800;font-size:34px;line-height:1.02;letter-spacing:-.035em">{"Paper Satellites" if sp else "Tidewater"}</div>'
             f'<div style="margin-top:6px;font-weight:600;font-size:15px;color:rgba(255,255,255,.72)">{"Velvet Orchard" if sp else "Lumen Harbor"}</div></div>')
    y += 112 if sp else 100
    # up-next timeline (#464), solid
    rows=[]
    if sp:
        rows=[("now","Tidewater","Lumen Harbor","ending"),("next","Paper Satellites","Velvet Orchard","3:58"),("song","Salt & Neon","The Quiet Arcades","4:12")]
    else:
        rows=[("now","Tidewater","Lumen Harbor","now"),("dj","DJ break after this song","",""),("song","Paper Satellites","Velvet Orchard","3:58"),("song","Salt & Neon","The Quiet Arcades","4:12")]
    PILL_Y=676; TUN_Y=PILL_Y-12-104
    if not sp:
        extra=[("song","Harbor Lights Again","Mira Vale","3:31"),("song","Cinder Coast","Northbound Choir","3:47")]
        while 40+(len(rows)+1)*42 <= TUN_Y-12-y and extra: rows.append(extra.pop(0))
    th=TUN_Y-12-y
    b.append(f'<div class="solid" style="left:{RX}px;top:{y}px;width:{RW}px;height:{th}px"></div>')
    inner=f'<div class="lbl" style="margin-bottom:8px">Up next</div>'
    for i,(k,t,a,d) in enumerate(rows):
        last=i==len(rows)-1
        line='' if last else '<div class="a" style="left:7px;top:22px;width:2px;height:34px;background:rgba(255,255,255,.14)"></div>'
        if k=="dj":
            node=f'<div class="a" style="left:-1px;top:6px">{orb("ready",18)}</div>'
            txt=f'<div style="font-weight:800;font-size:13.5px;color:#ffc9a3;line-height:30px">{t}</div>'
        else:
            col = f"rgb({TEAL})" if k=="now" else "rgba(255,255,255,.35)"
            node=f'<div class="a" style="left:2px;top:9px;width:12px;height:12px;border-radius:50%;background:{col if k=="now" else "transparent"};border:2px solid {col}"></div>'
            txt=(f'<div style="display:flex;justify-content:space-between;align-items:baseline"><span style="font-weight:800;font-size:14px;{"color:rgb("+TEAL+")" if k=="now" else ""}">{t}</span>'
                 f'<span style="font-size:10.5px;font-weight:700;color:rgba(255,255,255,.55)">{d}</span></div>'
                 f'<div style="font-size:11.5px;font-weight:600;color:rgba(255,255,255,.62);margin-top:1px">{a}</div>')
        inner+=f'<div style="position:relative;height:42px;padding-left:26px">{line}{node}{txt}</div>'
    b.append(f'<div class="a" style="left:{RX+16}px;top:{y+14}px;width:{RW-32}px">{inner}</div>')
    y=TUN_Y
    # tuner dial (#463), glass
    tH=104
    chips=[("Night Owl","owl",False),("Morning Calm","calm",True),("Static Bloom","bloom",False)]
    ch=""
    for n,k,sel in chips:
        if sel:
            ch+=(f'<div style="flex:none;height:48px;padding:0 14px 0 6px;border-radius:24px;display:flex;align-items:center;gap:8px;'
                 f'background:rgba({TEAL},.95);color:#04201c;font-weight:800;font-size:13px">{art_small(36,k,18)}{n}</div>')
        else:
            ch+=(f'<div style="flex:none;height:44px;padding:0 12px 0 5px;border-radius:22px;display:flex;align-items:center;gap:7px;'
                 f'background:rgba(255,255,255,.10);font-weight:700;font-size:12.5px;color:rgba(255,255,255,.85)">{art_small(34,k,17)}{n}</div>')
    ticks="".join(f'<div style="width:{2 if i==10 else 1}px;height:{12 if i==10 else (7 if i%2==0 else 4)}px;background:{"#fff" if i==10 else "rgba(255,255,255,.4)"}"></div>' for i in range(21))
    b.append(f'<div class="glass" style="left:{RX}px;top:{y}px;width:{RW}px;height:{tH}px;border-radius:28px;overflow:hidden">'
             f'<div class="a" style="left:16px;top:12px;right:16px;display:flex;justify-content:space-between;align-items:center"><span class="lbl" style="color:rgba(255,255,255,.85)">Tuner</span>'
             f'<div style="display:flex;gap:4px;align-items:flex-end;height:12px">{ticks}</div></div>'
             f'<div class="a" style="left:-96px;top:40px;display:flex;gap:8px;align-items:center">{ch}</div>'
             f'<div class="a" style="left:0;top:34px;width:26px;height:60px;background:linear-gradient(90deg,rgba(10,30,30,.6),transparent)"></div>'
             f'<div class="a" style="right:0;top:34px;width:26px;height:60px;background:linear-gradient(270deg,rgba(10,30,30,.6),transparent)"></div></div>')
    y+=tH+12
    # transport pill, glass; only play is tinted
    pH=76
    b.append(f'<div class="glass" style="left:{RX}px;top:{y}px;width:{RW}px;height:{pH}px;border-radius:38px">'
             f'<div class="btn" style="left:22px;top:16px;width:44px;height:44px">{I_prev(26)}</div>'
             f'<div class="btn" style="left:{RW/2-30}px;top:8px;width:60px;height:60px;background:#fff;box-shadow:0 0 0 6px rgba({TEAL},.25)">{I_pause(26,"#071512") if sp else I_pause(26,"#071512")}</div>'
             f'<div class="btn" style="left:{RW-66}px;top:16px;width:44px;height:44px">{I_next(26)}</div></div>')
    y+=pH
    # ---- symbol bar (56 pt, system vertical bar, glass) ----
    icons=[I_down(22),I_more(22),I_queue(22),I_tune(22)]
    btns="".join(f'<div style="width:44px;height:44px;border-radius:22px;display:flex;align-items:center;justify-content:center;{"background:rgba(255,255,255,.14)" if i==3 else ""}">{ic}</div>' for i,ic in enumerate(icons))
    badge = (f'<div style="width:44px;height:44px;display:flex;align-items:center;justify-content:center"><div style="width:12px;height:12px;border-radius:50%;background:{RED};box-shadow:0 0 10px {RED},0 0 22px rgba(255,59,47,.6)"></div></div>'
             if sp else f'<div style="width:44px;height:44px;display:flex;align-items:center;justify-content:center">{orb("ready",22)}</div>')
    b.append(f'<div class="glass" style="left:{BX_+6}px;top:58px;width:{BW-6}px;height:{y-58}px;border-radius:25px;display:flex;flex-direction:column;align-items:center;justify-content:space-between;padding:6px 0">'
             f'<div style="display:flex;flex-direction:column;gap:10px">{btns}</div>{badge}</div>')
    # ---- motion annotation strip (bottom, split so it never crosses the band) ----
    ay=max(y,ry+48)+14
    lt=(f'<span class="k">TUNE</span>Detent snap plus a haptic; the station colour washes across in about 250 ms. '
        f'<span class="k">IDLE</span>Nothing loops. <span class="k">A11Y</span>Reduce Motion gives a crossfade; Reduce Transparency gives solid glass.')
    rt=(f'<span class="k">HANDOFF</span>The art eases to 0.94 and the orb rises on a spring of about 400 ms. Return is the reverse. '
        if sp else f'<span class="k">READY</span>The ring breathes only while .ready. No tally until a confirmed .speaking. A failed break is a quiet skip. ')
    b.append(f'<div class="ann" style="left:{LX}px;top:{ay}px;width:{LW}px;padding-top:8px;border-top:1px solid rgba(255,255,255,.14)">{lt}</div>')
    b.append(f'<div class="ann" style="left:{RX}px;top:{ay}px;width:{RW+BW-6+6}px;padding-top:8px;border-top:1px solid rgba(255,255,255,.14)">{rt}Glass is used only on the control layer.</div>')
    return "".join(b), y
if __name__=="__main__":
    X=".rail .tally{box-shadow:0 0 0 1px rgba(255,140,120,.5),0 0 12px rgba(255,59,47,.7)}"
    body,y=build("speaking"); print("speaking rail bottom",y); page("02-unfolded-speaking",W,H,body,X)
    body,y=build("ready"); print("ready rail bottom",y); page("02b-unfolded-ready",W,H,body)
