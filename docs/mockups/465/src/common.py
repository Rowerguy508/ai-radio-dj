# OnAirly 2.0 · #465 hi-fi mockups · shared pieces (Nova)
import subprocess, os
OUT = os.path.dirname(os.path.abspath(__file__)) + "/.."
RED = "#ff3b2f"
TEAL = "47,212,190"      # Morning Calm station tint (rgb)
CSS = r"""
*{box-sizing:border-box;margin:0;padding:0}
html,body{width:%(w)spx;height:%(h)spx;overflow:hidden}
body{position:relative;font-family:'Plus Jakarta Sans',Inter,system-ui,sans-serif;color:#fff;background:#06080c;
 -webkit-font-smoothing:antialiased;font-feature-settings:'ss01','tnum'}
.a{position:absolute}
.glass{position:absolute;background:linear-gradient(140deg,rgba(255,255,255,.20),rgba(255,255,255,.05) 45%%,rgba(255,255,255,.10)),rgba(var(--tint),.12);
 -webkit-backdrop-filter:blur(26px) saturate(190%%);backdrop-filter:blur(26px) saturate(190%%);
 border:1px solid rgba(255,255,255,.24);box-shadow:inset 0 1px 0 rgba(255,255,255,.45),inset 0 -1px 0 rgba(255,255,255,.08),0 14px 34px rgba(0,0,0,.38)}
.solid{position:absolute;background:#11151c;border-radius:28px}
.cap{position:absolute;font:600 9px/1.2 'Inter',sans-serif;letter-spacing:.06em;color:rgba(255,255,255,.62);text-transform:uppercase;white-space:nowrap}
.cap b{color:rgba(255,255,255,.85);font-weight:700}
.lbl{font-weight:800;font-size:10px;letter-spacing:.16em;text-transform:uppercase;color:rgba(255,255,255,.72)}
.sample{display:inline-block;font:800 8.5px/1 Inter,sans-serif;letter-spacing:.14em;color:#1a1200;background:#ffd23f;border-radius:5px;padding:3px 5px 2px;vertical-align:middle}
.tally{display:inline-flex;align-items:center;gap:7px;height:28px;padding:0 12px 0 10px;border-radius:14px;background:#e0261c;
 color:#fff;font-weight:800;font-size:12px;letter-spacing:.18em;box-shadow:0 0 0 1px rgba(255,140,120,.5),0 0 22px rgba(255,59,47,.75),0 0 60px rgba(255,59,47,.35)}
.tally i{width:8px;height:8px;border-radius:50%%;background:#fff;box-shadow:0 0 8px #fff}
.btn{position:absolute;display:flex;align-items:center;justify-content:center;border-radius:50%%}
.ann{position:absolute;font:500 8.6px/1.35 Inter,sans-serif;color:rgba(255,255,255,.66);letter-spacing:.01em}
.ann b{color:#fff;font-weight:700}
.ann .k{display:inline-block;color:rgba(%(teal)s,1);font-weight:800;letter-spacing:.12em;font-size:8px;margin-right:3px}
.flag{position:absolute;font:800 9px/1.25 Inter,sans-serif;letter-spacing:.08em;text-transform:uppercase;color:#1a1200;background:#ffd23f;border-radius:8px;padding:6px 9px}
.redact{display:inline-block;height:.72em;border-radius:6px;background:rgba(255,255,255,.28);vertical-align:middle}
"""
def page(name, w, h, body, extra_css=""):
    css = CSS % {"w": w, "h": h, "red": RED, "teal": TEAL}
    html = f'<!doctype html><html><head><meta charset="utf-8"><style>{css}{extra_css}</style></head><body style="--tint:{TEAL}">{body}</body></html>'
    p = f"{OUT}/src/{name}.html"
    open(p, "w").write(html)
    png = f"{OUT}/{name}.png"
    subprocess.run(["google-chrome", "--headless=new", "--no-sandbox", "--disable-gpu-sandbox", "--hide-scrollbars","--allow-file-access-from-files",
                    "--force-device-scale-factor=3", f"--window-size={w},{h}", "--virtual-time-budget=1500",
                    f"--screenshot={png}", "file://" + p], check=True, capture_output=True)
    print("rendered", png)

# ---------- icons (inline SVG, custom) ----------
def svg(inner, s=24, vb=24, c="#fff", sw=2.2, fill="none"):
    return (f'<svg width="{s}" height="{s}" viewBox="0 0 {vb} {vb}" fill="{fill}" stroke="{c}" stroke-width="{sw}" '
            f'stroke-linecap="round" stroke-linejoin="round">{inner}</svg>')
def I_play(s=26, c="#fff"):  return svg('<path d="M7.5 4.8c0-1 1.1-1.6 1.9-1.1l11 6.9c.8.5.8 1.7 0 2.2l-11 6.9c-.8.5-1.9-.1-1.9-1.1z"/>', s, c=c, fill=c, sw=1)
def I_pause(s=26, c="#fff"): return svg('<rect x="5.5" y="4" width="4.6" height="16" rx="1.6"/><rect x="13.9" y="4" width="4.6" height="16" rx="1.6"/>', s, c=c, fill=c, sw=0)
def I_next(s=24, c="#fff"):  return svg('<path d="M4 6.2c0-.8.9-1.3 1.6-.8l8 5.6c.6.4.6 1.3 0 1.7l-8 5.6c-.7.5-1.6 0-1.6-.8z"/><rect x="16.6" y="5" width="3.2" height="14" rx="1.3"/>', s, c=c, fill=c, sw=0)
def I_prev(s=24, c="#fff"):  return svg('<g transform="translate(24 0) scale(-1 1)"><path d="M4 6.2c0-.8.9-1.3 1.6-.8l8 5.6c.6.4.6 1.3 0 1.7l-8 5.6c-.7.5-1.6 0-1.6-.8z"/><rect x="16.6" y="5" width="3.2" height="14" rx="1.3"/></g>', s, c=c, fill=c, sw=0)
def I_back(s=22, c="#fff"):  return svg('<path d="M15 5l-7 7 7 7"/>', s, c=c, sw=2.6)
def I_down(s=22, c="#fff"):  return svg('<path d="M5 9l7 7 7-7"/>', s, c=c, sw=2.6)
def I_more(s=22, c="#fff"):  return svg('<circle cx="5" cy="12" r="1.9"/><circle cx="12" cy="12" r="1.9"/><circle cx="19" cy="12" r="1.9"/>', s, c=c, fill=c, sw=0)
def I_queue(s=22, c="#fff"): return svg('<path d="M4 6h11M4 12h11M4 18h7"/><path d="M17 15.5l4 2.5-4 2.5z" fill="%s"/>' % c, s, c=c)
def I_tune(s=22, c="#fff"):  return svg('<circle cx="12" cy="13" r="7.5"/><path d="M12 13l3.6-3.6"/><path d="M12 2.5v2.2M3.2 6.6l1.5 1.4M20.8 6.6l-1.5 1.4"/>', s, c=c)
def I_up(s=20, c="#fff"):    return svg('<path d="M7 11v9H4.5a1 1 0 0 1-1-1v-7a1 1 0 0 1 1-1zM7 11l4-7.5c1.6 0 2.6 1.2 2.3 2.8L12.8 10H19a2 2 0 0 1 2 2.3l-1.1 6.3A2 2 0 0 1 18 20H7"/>', s, c=c, sw=2)
def I_downv(s=20, c="#fff"): return '<span style="display:inline-block;transform:rotate(180deg)">' + I_up(s, c) + '</span>'
def I_radio(s=22, c="#fff"): return svg('<rect x="3" y="8" width="18" height="12" rx="3"/><path d="M7 8l9-4.5"/><circle cx="15.5" cy="14" r="2.6"/><path d="M6.5 12.5h3M6.5 15.5h3"/>', s, c=c)
def I_stack(s=22, c="#fff"): return svg('<rect x="4" y="9" width="16" height="11" rx="3"/><path d="M6.5 6h11M9 3h6"/>', s, c=c)
def I_gear(s=22, c="#fff"):  return svg('<circle cx="12" cy="12" r="3.2"/><path d="M12 2.8v2.6M12 18.6v2.6M2.8 12h2.6M18.6 12h2.6M5.5 5.5l1.8 1.8M16.7 16.7l1.8 1.8M5.5 18.5l1.8-1.8M16.7 7.3l1.8-1.8"/>', s, c=c)
def I_wave(s=22, c="#fff"):  return svg('<circle cx="12" cy="12" r="2.4" fill="%s"/><path d="M7.8 7.8a6 6 0 0 0 0 8.4M16.2 7.8a6 6 0 0 1 0 8.4M5 5a10 10 0 0 0 0 14M19 5a10 10 0 0 1 0 14"/>' % c, s, c=c)
def I_lock(s=14, c="#fff"):  return svg('<rect x="5" y="10.5" width="14" height="10" rx="2.5"/><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3"/>', s, c=c)

# ---------- generated album / station art ----------
def art_tidewater(w, h, r=28, extra=""):
    """'Tidewater' by Lumen Harbor (fictional): low sun over layered tide bands."""
    bands = "".join(
        f'<path d="M0 {y} C {w*.25} {y-a} {w*.5} {y+a} {w*.75} {y-a*.4} S {w} {y+a*.3} {w} {y} V {h} H 0 Z" fill="{c}"/>'
        for y, a, c in [(h*.58, h*.05, "#0f6f78"), (h*.66, h*.06, "#0b525e"), (h*.75, h*.05, "#083d4a"), (h*.85, h*.04, "#062b37")])
    shimmer = "".join(f'<rect x="{w*(.36+.02*(i%3))}" y="{h*(.585+.025*i)}" width="{w*(.28-.03*i)}" height="{h*.008}" rx="2" fill="rgba(255,214,160,{.55-.08*i})"/>' for i in range(6))
    return (f'<div class="a" style="width:{w}px;height:{h}px;border-radius:{r}px;overflow:hidden;{extra}">'
            f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}"><defs>'
            f'<linearGradient id="sky" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#16324f"/><stop offset=".45" stop-color="#d86a4a"/><stop offset=".6" stop-color="#ffb26b"/></linearGradient>'
            f'<radialGradient id="sun" cx=".5" cy=".5" r=".5"><stop offset="0" stop-color="#fff4d6"/><stop offset=".6" stop-color="#ffd08a"/><stop offset="1" stop-color="#ffb26b" stop-opacity="0"/></radialGradient></defs>'
            f'<rect width="{w}" height="{h}" fill="url(#sky)"/>'
            f'<circle cx="{w*.5}" cy="{h*.56}" r="{w*.26}" fill="url(#sun)"/><circle cx="{w*.5}" cy="{h*.56}" r="{w*.15}" fill="#fff1cf"/>'
            f'{bands}{shimmer}'
            f'<text x="{w*.07}" y="{h*.13}" font-family="Plus Jakarta Sans" font-weight="800" font-size="{w*.075}" fill="rgba(255,255,255,.92)" letter-spacing="{w*.004}">LUMEN HARBOR</text>'
            f'<text x="{w*.07}" y="{h*.13+w*.075}" font-family="Plus Jakarta Sans" font-weight="500" font-size="{w*.05}" fill="rgba(255,255,255,.7)">Tidewater</text>'
            f'</svg></div>')
def art_small(w, kind, r=10):
    pal = {"satellites": ("#2a1b5e", "#7c4dff", "#ff8ad8"), "neon": ("#3b0d2b", "#ff3d7f", "#ffd23f"),
           "owl": ("#0d1430", "#3753c9", "#9fb3ff"), "bloom": ("#1d0b2e", "#c13cff", "#55e0ff"), "calm": ("#06303a", "#2fd4be", "#ffd08a")}[kind]
    a, b, c = pal
    return (f'<div style="width:{w}px;height:{w}px;border-radius:{r}px;flex:none;background:'
            f'radial-gradient(circle at 70% 30%,{c} 0 18%,transparent 19%),'
            f'conic-gradient(from 210deg at 35% 70%,{b},{a},{b});"></div>')

# ---------- DJ orb (one object, three states) ----------
def orb(state, d):
    if state == "idle":   # small dim static ember, mic down
        return (f'<div style="width:{d}px;height:{d}px;border-radius:50%;background:radial-gradient(circle at 40% 38%,#8a4a2c,#4a2216 60%,#2a130d);'
                f'box-shadow:0 0 {d*.6}px rgba(160,70,40,.28),inset 0 0 0 1px rgba(255,150,110,.18)"></div>')
    if state == "ready":  # one slow breathing ring, no label
        core = d*.42
        return (f'<div style="position:relative;width:{d}px;height:{d}px">'
                f'<div class="a" style="inset:0;border-radius:50%;border:2px solid rgba(255,186,140,.85);box-shadow:0 0 {d*.25}px rgba(255,150,100,.35),inset 0 0 {d*.2}px rgba(255,150,100,.18)"></div>'
                f'<div class="a" style="left:{(d-core)/2}px;top:{(d-core)/2}px;width:{core}px;height:{core}px;border-radius:50%;'
                f'background:radial-gradient(circle at 40% 36%,#ffcf9e,#e8743f 62%,#9c3a1e);box-shadow:0 0 {d*.3}px rgba(255,140,80,.45)"></div></div>')
    # speaking: hero orb, warm, live, no waveform
    return (f'<div style="position:relative;width:{d}px;height:{d}px">'
            f'<div class="a" style="inset:-{d*.32}px;border-radius:50%;background:radial-gradient(circle,rgba(255,70,45,.42),rgba(255,59,47,.12) 45%,transparent 70%)"></div>'
            f'<div class="a" style="inset:-{d*.14}px;border-radius:50%;border:1.5px solid rgba(255,140,110,.35)"></div>'
            f'<div class="a" style="inset:0;border-radius:50%;background:radial-gradient(circle at 38% 32%,#fff2dc 0,#ffb46e 22%,#ff5a32 55%,#c8141f 88%,#8a0b16);'
            f'box-shadow:0 0 {d*.35}px rgba(255,70,40,.75),inset 0 -{d*.08}px {d*.2}px rgba(120,0,10,.55),inset 0 {d*.05}px {d*.12}px rgba(255,240,220,.5)"></div>'
            f'<div class="a" style="left:{d*.2}px;top:{d*.12}px;width:{d*.34}px;height:{d*.2}px;border-radius:50%;background:radial-gradient(ellipse,rgba(255,255,255,.7),transparent 70%)"></div></div>')

def onairly_mark(size=13):
    return (f'<span style="display:inline-flex;align-items:center;gap:{size*.4}px;font-weight:800;font-size:{size}px;letter-spacing:-.01em">'
            f'<span style="width:{size*.78}px;height:{size*.78}px;border-radius:50%;border:{size*.16}px solid #fff;display:inline-flex;align-items:center;justify-content:center">'
            f'<span style="width:{size*.22}px;height:{size*.22}px;border-radius:50%;background:{RED}"></span></span>OnAirly</span>')
