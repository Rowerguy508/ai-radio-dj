from common import *
W,H=640,820
rows=[("idle","Idle","mic down",18,".idle",
       "A small, dim, static ember that sits in the rail. It has no glow pulse and no label. It just says the mic is down."),
      ("ready","Ready","break queued",64,".ready",
       "One slow breathing ring (4 s cycle, only while .ready), with no tally and no label. The up-next timeline carries the break line."),
      ("speaking","Speaking","confirmed .speaking only",104,".speaking · onAirLabel",
       "The orb grows to be the hero of the right half and the warm red On Air tally lights. No waveform is drawn unless a real output level exists.<br><br><span style='color:rgba(255,255,255,.6)'>The tally is a solid warm red (#E0261C) with white text at 4.7:1, and it glows #FF3B2F. Under Reduce Motion the halo is dropped and the orb crossfades in.</span>")]
b=[f'<div class="a" style="inset:0;background:radial-gradient(120% 70% at 85% 62%,rgba(255,59,47,.20),transparent 55%),radial-gradient(90% 60% at 0% 0%,rgba({TEAL},.16),transparent 60%),#06080c"></div>',
   f'<div class="cap" style="left:24px;top:18px"><b>00 · DJ orb states</b> · 640×820 pt sheet · OnAirly 2.0 · #465</div>',
   f'<div class="a" style="left:24px;top:56px">{onairly_mark(15)}</div>',
   f'<div class="a" style="left:24px;top:84px;font-weight:800;font-size:40px;line-height:1;letter-spacing:-.03em">One orb.<br>Three states.</div>',
   f'<div class="a" style="left:24px;top:178px;width:580px;font-weight:500;font-size:13px;line-height:1.45;color:rgba(255,255,255,.74)">'
   f'Driven only by published DJ state, <b style="color:#fff">never by a timer or a guess</b>. Same source as <span style="font-family:monospace;color:#fff">DJStudioState.onAirLabel</span>. A failed break is a quiet skip: the orb drops back to idle and nothing shows on screen.</div>']
y=244
hs=[100,100,206]
for (st,name,sub,d,src,desc),hh in zip(rows,hs):
    b.append(f'<div class="solid" style="left:24px;top:{y}px;width:592px;height:{hh}px"></div>')
    # rail swatch
    b.append(f'<div class="a" style="left:40px;top:{y+16}px;width:{200 if st=="speaking" else 150}px;height:{hh-32}px;border-radius:20px;background:#090c11;display:flex;align-items:center;justify-content:center;overflow:hidden">{orb(st,d)}</div>')
    tx=264 if st=="speaking" else 210
    tally=f'<span class="tally" style="margin-left:10px;transform:scale(.86);transform-origin:left center"><i></i>ON AIR</span>' if st=="speaking" else ''
    b.append(f'<div class="a" style="left:{tx}px;top:{y+16}px;width:{604-tx}px">'
             f'<div style="display:flex;align-items:center"><span style="font-weight:800;font-size:24px;letter-spacing:-.02em">{name}</span>{tally}</div>'
             f'<div class="lbl" style="margin-top:5px;color:rgba({TEAL},1)">{sub}<span style="font:600 9.5px monospace;letter-spacing:0;text-transform:none;color:rgba(255,255,255,.5);margin-left:8px">{src}</span></div>'
             f'<div style="margin-top:6px;font-size:12px;line-height:1.42;color:rgba(255,255,255,.78);font-weight:500">{desc}</div>'
             f'</div>')
    y+=hh+12
b.append(f'<div class="a" style="left:24px;top:{y+4}px;width:592px;height:1px;background:rgba(255,255,255,.12)"></div>')
ann=[("TUNE","Detent snap plus a haptic, then the station colour washes across in about 250 ms."),
     ("HANDOFF","The art eases to 0.94 scale and the orb rises out of the rail on a spring of about 400 ms."),
     ("RETURN","The exact reverse when the break ends or is skipped."),
     ("IDLE","Nothing loops while idle. Only the ready ring breathes, and only while .ready."),
     ("ACCESS","Reduce Motion gives a crossfade with no pulse. Reduce Transparency gives a solid fill.")]
b.append(f'<div class="a" style="left:24px;top:{y+16}px;width:592px;display:grid;grid-template-columns:1fr 1fr;gap:8px 22px">'+
         "".join(f'<div class="ann" style="position:static;font-size:9.5px"><span class="k">{k}</span>{v}</div>' for k,v in ann)+'</div>')
page("00-orb-states",W,H,"".join(b))
