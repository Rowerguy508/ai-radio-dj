#!/usr/bin/env python3
"""Render Sentinel's docs/site/{privacy,support}.md into site/{privacy,support}.html.

The page copy is kept word for word: only Markdown syntax becomes HTML, and every
[owner ...] / [PENDING ...] marker stays as literal text inside <mark>. The leading
"> " block is the editorial note for the owner, not page copy, so it is left out and
replaced by the site's draft banner. The page shell (head, header, footer) is kept
from the existing HTML file. No dependencies. Usage: python3 site/render-copy.py [--check]
(--check exits 1 if a page is out of date with its .md instead of writing it.)
"""
import html, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "site"
PAGES = {"privacy": "p", "support": "s"}
BANNER = ('<div class="draft-banner" role="note">\n'
          '  <p>Draft, not for publication. Every highlighted [owner] and [PENDING] marker has to be '
          'resolved by the owner, and nothing marked [PENDING] goes live until it ships.</p>\n</div>')

def inline(text):
    out, i = [], 0
    tok = re.compile(r"\[([^\]]+)\]\(([^)]+)\)|\*\*(.+?)\*\*|`([^`]+)`|(?<!\w)_(.+?)_(?!\w)|\[((?:owner|PENDING)[^\]]*)\]")
    for m in tok.finditer(text):
        out.append(html.escape(text[i:m.start()], quote=False))
        if m.group(1) is not None:
            out.append(f'<a href="{html.escape(m.group(2))}">{inline(m.group(1))}</a>')
        elif m.group(3) is not None:
            out.append(f"<strong>{inline(m.group(3))}</strong>")
        elif m.group(4) is not None:
            out.append(f"<code>{html.escape(m.group(4), quote=False)}</code>")
        elif m.group(5) is not None:
            out.append(f"<em>{inline(m.group(5))}</em>")
        else:
            out.append(f'<mark class="owner">[{html.escape(m.group(6), quote=False)}]</mark>')
        i = m.end()
    out.append(html.escape(text[i:], quote=False))
    return "".join(out)

def slug(prefix, text):
    s = re.sub(r"\[[^\]]*\]", "", text).lower()
    return prefix + "-" + re.sub(r"[^a-z0-9]+", "-", s).strip("-")

def render(md, prefix):
    lines = md.splitlines()
    body, blocks, para, lst = [], [], [], None
    in_section = False
    def flush():
        nonlocal para, lst
        if para:
            blocks.append(f"      <p>{inline(' '.join(para))}</p>"); para = []
        if lst:
            tag, items = lst
            blocks.append(f"      <{tag}>\n" + "\n".join(f"        <li>{inline(x)}</li>" for x in items) + f"\n      </{tag}>")
            lst = None
    def close_section():
        nonlocal in_section, blocks
        flush()
        if in_section:
            body.extend(blocks); body.append("    </section>")
        else:
            body.extend(b.replace("      ", "    ", 1) for b in blocks)
        blocks = []
    for ln in lines:
        if ln.startswith(">"):
            continue
        if ln.startswith("# "):
            flush(); blocks.append(f"      <h1>{inline(ln[2:])}</h1>")
        elif ln.startswith("## "):
            close_section()
            t = ln[3:]; sid = slug(prefix, t)
            cls = ' class="is-pending"' if "[PENDING" in t else ""
            body.append(f'    <section{cls} aria-labelledby="{sid}">')
            blocks.append(f'      <h2 id="{sid}">{inline(t)}</h2>')
            in_section = True
        elif re.match(r"^\d+\. ", ln) or ln.startswith("- "):
            tag = "ol" if ln[0].isdigit() else "ul"
            if para: flush()
            if not lst or lst[0] != tag: flush(); lst = (tag, [])
            lst[1].append(re.sub(r"^(\d+\.|-) ", "", ln))
        elif not ln.strip():
            flush()
        elif prefix == "s" and ln.startswith("**") and not para:
            flush(); blocks.append(f'      <h3 class="q">{inline(ln)}</h3>')
        else:
            if lst: flush()
            para.append(ln)
    close_section()
    return "\n".join(body)

def main():
    check = "--check" in sys.argv[1:]
    stale = 0
    for name, prefix in PAGES.items():
        md_path = ROOT / "docs/site" / f"{name}.md"
        page = SITE / f"{name}.html"
        shell = page.read_text()
        start = shell.index('<main id="main" class="doc">')
        end = shell.index("</main>")
        main_html = ('<main id="main" class="doc">\n  <div class="wrap narrow">\n'
                     f'    <!-- Copy: docs/site/{name}.md from sentinel/site-copy (#261) at 7f61c51, rendered by site/render-copy.py. Do not edit the copy here; change the .md and re-render. -->\n'
                     f"    {BANNER}\n\n{render(md_path.read_text(), prefix)}\n  </div>\n")
        new = shell[:start] + main_html + shell[end:]
        if check:
            if new != shell:
                stale = 1; print(f"FAIL: {page.relative_to(ROOT)} is out of date with {md_path.relative_to(ROOT)}")
            continue
        page.write_text(new)
        print(f"rendered {md_path.relative_to(ROOT)} -> {page.relative_to(ROOT)}")
    return stale

if __name__ == "__main__":
    sys.exit(main())
