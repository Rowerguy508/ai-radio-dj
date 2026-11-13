from common import *
W,H=844,390
def build(redacted):
    b=[f'<div class="a" style="inset:0;background:#000"></div>',
       f'<div class="cap" style="left:20px;top:12px"><b>04{"b" if redacted else ""} · StandBy · {"redacted (default while locked)" if redacted else "DJ speaking · after Face ID"}</b> · 844×390 pt · assumed size (folded, rotated)</div>']
    # clock widget (left)
    b.append(f'<div class="a" style="left:20px;top:40px;width:400px;height:330px;border-radius:36px;background:radial-gradient(90% 80% at 30% 30%,rgba({TEAL},.22),transparent 70%),#0b0f14"></div>')
    b.append(f'<div class="a" style="left:44px;top:70px;font-weight:800;font-size:150px;line-height:1;letter-spacing:-.06em;color:#eafffb">9:41</div>')
    b.append(f'<div class="a" style="left:52px;top:240px;font-weight:700;font-size:16px;color:rgba(255,255,255,.72)">Thu 12 Nov</div>')
    b.append(f'<div class="a" style="left:52px;top:300px;display:flex;align-items:center;gap:8px">{onairly_mark(14)}<span style="font-size:12px;font-weight:600;color:rgba(255,255,255,.62)">clock radio</span></div>')
    # radio widget (right)
    b.append(f'<div class="a" style="left:432px;top:40px;width:392px;height:330px;border-radius:36px;overflow:hidden;background:radial-gradient(80% 70% at 85% 10%,rgba(255,59,47,{.0 if redacted else .30}),transparent 70%),radial-gradient(90% 90% at 10% 100%,rgba({TEAL},.22),transparent 70%),#0b0f14"></div>')
    dot=(f'<div style="display:flex;align-items:center;gap:8px"><div style="width:14px;height:14px;border-radius:50%;background:{RED};box-shadow:0 0 10px {RED},0 0 26px rgba(255,59,47,.7)"></div>'
         f'<span style="font-weight:800;font-size:12px;letter-spacing:.18em;color:#ff8a7f">ON AIR</span></div>')
    if redacted:
        art=f'<div style="width:120px;height:120px;border-radius:24px;background:rgba(255,255,255,.12)"></div>'
        st=f'<span class="redact" style="width:150px;height:28px"></span>'
        tr=f'<span class="redact" style="width:200px;height:20px"></span>'
        ar=f'<span class="redact" style="width:120px;height:14px"></span>'
    else:
        art=art_tidewater(120,120,24,"position:relative")
        st=f'Morning Calm'
        tr='Tidewater'; ar='Lumen Harbor'
    b.append(f'<div class="a" style="left:460px;top:62px;width:340px;display:flex;justify-content:space-between;align-items:flex-start">{art}{dot}</div>')
    b.append(f'<div class="a" style="left:460px;top:194px;width:340px">'
             f'<div class="lbl" style="color:rgb({TEAL})">Station</div>'
             f'<div style="font-weight:800;font-size:28px;letter-spacing:-.03em;margin-top:6px;line-height:1.1">{st}</div>'
             f'<div style="font-weight:700;font-size:18px;margin-top:10px">{tr}</div>'
             f'<div style="font-weight:600;font-size:14px;color:rgba(255,255,255,.7);margin-top:6px">{ar}</div></div>')
    note=("privacySensitive is on by default: while the phone is locked, station, track, artist and art are redacted. The time and the on-air dot stay visible. No script or briefing text, ever."
          if redacted else
          "Display fields only: station, track, artist, art and DJ state from the App Group. No tokens, user ID, consent state, tester_voice, script or briefing text. The dot shows only on confirmed .speaking (onAirLabel).")
    b.append(f'<div class="ann" style="left:460px;top:322px;width:344px;font-size:8.4px;color:rgba(255,255,255,.55)">{note}</div>')
    return "".join(b)
page("04-standby",W,H,build(False))
page("04b-standby-redacted",W,H,build(True))
