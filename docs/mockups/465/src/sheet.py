from common import *
W,H=1720,1080
def im(n,h,label):
    return f'<figure style="margin:0;display:flex;flex-direction:column;gap:8px"><img src="../{n}.png" style="height:{h}px;border-radius:14px;display:block;border:1px solid rgba(255,255,255,.12)"><figcaption style="font:600 11px Inter;color:rgba(255,255,255,.7)">{label}</figcaption></figure>'
b=(f'<div class="a" style="inset:0;background:radial-gradient(60% 50% at 10% 0%,rgba({TEAL},.18),transparent 60%),radial-gradient(50% 50% at 100% 100%,rgba(255,59,47,.14),transparent 60%),#05070a"></div>'
   f'<div class="a" style="left:40px;top:28px;display:flex;align-items:baseline;gap:16px">{onairly_mark(22)}<span style="font-weight:800;font-size:22px">2.0 · iPhone Duo revamp · hi-fi mockups</span>'
   f'<span style="font:600 12px Inter;color:rgba(255,255,255,.6)">#465 · tracker #466 · static design only, no code · only 640×820 is measured, every other size is assumed</span></div>'
   f'<div class="a" style="left:40px;top:80px;display:flex;gap:28px;align-items:flex-start">'
   + im("00-orb-states",440,"00 · Orb states · 640×820") + im("01-folded",440,"01 · Folded · 390×844 assumed")
   + im("02-unfolded-speaking",440,"02 · Unfolded, speaking · 640×820") + im("02b-unfolded-ready",440,"02b · Unfolded, ready · 640×820")
   + im("05-live-activity",440,"05 · Lock screen + Live Activity · 390×844 assumed") + '</div>'
   f'<div class="a" style="left:40px;top:580px;display:flex;gap:28px;align-items:flex-start">'
   + im("03-tent",440,"03 · Tent · 820×640 assumed")
   + '<div style="display:flex;flex-direction:column;gap:14px">' + im("04-standby",188,"04 · StandBy, speaking · 844×390 assumed") + im("04b-standby-redacted",188,"04b · StandBy, redacted default") + '</div></div>')

pts=[("Studio, not library","The right half of the unfolded screen is a live studio rail: orb, now playing, up-next timeline, tuner and glass transport."),
     ("One orb, real state","Idle is an ember, ready is a breathing ring, speaking is the hero orb with the red tally. It never runs on a timer, and a failed break is a quiet skip."),
     ("Glass on controls only","Liquid Glass is used only on the transport, the tuner, the symbol bar and the tab bar. Content stays solid and high-contrast."),
     ("Fold respected","The 28 pt band at x = 306 to 334 stays empty, and the 56 pt symbol bar sits on the outer edge (FoldedColumnLayout metrics)."),
     ("Lock screen and StandBy","These show station, track and the on-air dot only, redacted by default (privacySensitive), with no script text."),
     ("Open questions","The folded reskin needs the owner's yes. The tent pose API is unconfirmed in the 27.1 SDK. Folded, tent and lock-screen sizes are assumed.")]
b+=('<div class="a" style="left:1080px;top:600px;width:600px;display:flex;flex-direction:column;gap:16px">'+"".join(
    f'<div><div style="font-weight:800;font-size:16px">{t}</div><div style="font-size:13px;line-height:1.45;font-weight:500;color:rgba(255,255,255,.72);margin-top:3px">{d}</div></div>' for t,d in pts)+'</div>')
page("contact-sheet",W,H,b)
