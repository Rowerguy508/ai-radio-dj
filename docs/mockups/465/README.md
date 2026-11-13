# #465 · OnAirly 2.0 Duo revamp · high-fidelity mockups

These are static design mockups for owner review (tracker #466). They contain no app code and change nothing in the build. Each PNG is rendered at 3x from HTML/CSS in headless Chrome. The font is Plus Jakarta Sans (OFL). All art is generated from gradients and SVG, and every icon is custom SVG. Artists, songs and DJ lines are fictional, and all DJ copy is marked **SAMPLE**.

The unfolded frames use the real `FoldedColumnLayout` metrics: 16 pt edge, a 28 pt fold gutter centred on x = 320 (306 to 334 is kept empty), a 234 pt content column, a 56 pt symbol bar and 56 pt status clearance.

| File | Frame | Size (pt) | Caveats |
|---|---|---|---|
| `00-orb-states.png` | DJ orb: idle ember, ready ring, speaking hero with the On Air tally, plus motion notes | 640×820 sheet | Reference sheet |
| `01-folded.png` | Outer screen, compact player (idle, ember) with glass transport and tab bar | 390×844 | **Assumed size.** Reskin needs the owner's yes, because the iPhone path is byte-identical by rule |
| `02-unfolded-speaking.png` | Unfolded, DJ speaking: hero orb, On Air, SAMPLE caption, art at 0.94 | 640×820 | Measured |
| `02b-unfolded-ready.png` | Unfolded, DJ ready: ring, "DJ break after this song" in up next, no On Air | 640×820 | Measured |
| `03-tent.png` | Tent radio face: orb, big clock, station, with controls hidden behind a tap | 820×640 | **Assumed size.** Pose API unconfirmed in the 27.1 SDK |
| `04-standby.png` | StandBy clock radio, DJ speaking (after Face ID) | 844×390 | **Assumed size** |
| `04b-standby-redacted.png` | StandBy, default redacted (privacySensitive) | 844×390 | **Assumed size** |
| `05-live-activity.png` | Lock screen with a redacted Live Activity, plus Dynamic Island compact and expanded specimens | 390×844 | **Assumed size** |
| `contact-sheet.png` | All frames on one image | n/a | Composite: it shows ready and speaking frames side by side |

## Rules applied
- **Echo's rules.** "On Air" and the orb hero appear only with a confirmed `.speaking`. In ready, the only DJ line is "DJ break after this song", and no frame shows both. A failed break is a quiet skip with no error. The lock screen and StandBy show station, track and the on-air dot only, with no script or briefing text.
- **Sentinel's rules.** The lock screen and StandBy are redacted by default (`privacySensitive`). The App Group holds display fields only.
- **Liquid Glass** is used only on the control layer: the transport, the tuner, the symbol bar and the tab bar. Content is solid with radii of about 28 pt.
- **Motion** is described in the annotation strips: Tune is about 250 ms, the handoff is about 400 ms, nothing loops while idle, Reduce Motion gives a crossfade and Reduce Transparency gives solid fills.

`src/` holds the generators (`python3 f02.py`, etc., using headless `google-chrome`).

-Nova
