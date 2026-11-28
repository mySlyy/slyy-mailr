import json, re, html, glob, os, subprocess, sys
# Builds the Slyy Mailr Project Book from this folder. Run from anywhere: python3 docs/project-book/build.py
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
os.chdir(HERE)
env = {**os.environ, 'PYTHONPATH': os.path.join(ROOT, 'Tools', 'slyy-analytics')}
if '--no-analytics' not in sys.argv:
    subprocess.run([sys.executable, '-m', 'slyy_analytics', '--config', 'analytics.json'], cwd=ROOT, env=env, check=True, stdout=subprocess.DEVNULL)
    subprocess.run([sys.executable, '-m', 'slyy_analytics.export', '--review', os.path.join(HERE, 'data', 'review.json'),
                    '--cleanup', os.path.join(HERE, 'data', 'cleanup.json')], cwd=ROOT, env=env, check=True, stdout=subprocess.DEVNULL)
D = 'wireframes/'
A = os.path.join(ROOT, 'build', 'analytics', 'dash') + '/'
canvas = json.load(open(D + 'canvas.json'))
esc = html.escape

# ---------- wireframes ----------
boards = []
for name, b in canvas['boards'].items():
    src = open(D + name).read()
    inner = re.search(r'<x-dc>(.*)</x-dc>', src, re.S).group(1)
    inner = re.sub(r'<helmet>.*?</helmet>', '', inner, flags=re.S).strip()
    inner = re.sub(r'href="([A-Za-z]+)\.dc\.html"', lambda m: f'href="#wf-{m.group(1)}"', inner)
    code = re.search(r'<script type="text/x-dc"[^>]*>(.*?)</script>', src, re.S).group(1).strip()
    group = 'mobile' if b.get('page') == 'mobile' else ('agent' if name.startswith('Agent') else 'desktop')
    boards.append({'id': 'wf-' + name.replace('.dc.html', ''), 'title': b['title'], 'group': group, 'x': b['x'], 'y': b['y'],
                   'mobile': group == 'mobile', 'tpl': inner, 'code': code})
boards.sort(key=lambda b: (['desktop', 'agent', 'mobile'].index(b['group']), b['y'], b['x']))
groups = [('desktop', 'wf-desktop', 'Mac app', 'The six main windows: mail with an invitation, compose, account setup, calendar, new meeting, video call. Buttons work: answer the invite, add or remove the video link, mute in the call.'),
          ('agent', 'wf-agent', 'Ask Haven proposal', 'The AI agent in the writer, the reader and in search across all mail. Writes always ask first. Shipped in 0.6.0.'),
          ('mobile', 'wf-mobile', 'iPhone', 'Inbox, an invitation, the day view, a reminder with Join, and Ask Haven as a sheet.')]
wf_html = []
for g, gid, gname, gdesc in groups:
    wf_html.append(f'<h3 id="{gid}">{gname}</h3><p class="lead">{gdesc}</p>')
    bs = [b for b in boards if b['group'] == g]
    wf_html.append('<div class="boards' + (' phones' if g == 'mobile' else '') + '">')
    for b in bs:
        wf_html.append(f'<figure class="board" id="{b["id"]}"><figcaption>{esc(b["title"])}</figcaption><div class="frame"><div class="wf" data-wf="{b["id"]}"></div></div></figure>')
    wf_html.append('</div>')
wf_defs = ',\n'.join('{id:%s,tpl:%s,make:(DCLogic)=>{%s; return Component;}}' % (json.dumps(b['id']), json.dumps(b['tpl']).replace('</', '<\\/'), b['code']) for b in boards)
wf_toc = {g: [(b['id'], b['title']) for b in boards if b['group'] == g] for g, *_ in groups}

# ---------- backlog ----------
bl = open('backlog/backlog-source.html').read()
bl_js = re.search(r'<script>(.*?)</script>', bl, re.S).group(1)
upd = {22: ('D', 'B'), 30: ('N', 'B'), 31: ('D', 'B'), 44: ('N', 'B'), 58: ('N', 'B'), 68: ('D', 'B'), 69: ('N', 'B'), 78: ('N', 'D'),
       89: ('D', 'B'), 90: ('D', 'N'), 91: ('D', 'N'), 92: ('D', 'N')}
def fix(m):
    n = int(m.group(1)); line = m.group(0)
    if n in upd:
        mac, ios = upd[n]
        line = re.sub(r'", ([DBPTNW]), ([DBPTNW])', f'", {mac}, {ios}', line, count=1)
    if n == 77:
        line = line.replace('Needs the App Store Connect app record.', 'Blocked: needs the App Store Connect app record and an Admin API key.')
    return line
bl_js = re.sub(r'^\s*\[(\d+), "[a-z]+",.*$', fix, bl_js, flags=re.M)
new_items = '''
  [97, "acc", "Gmail and Google Workspace, with an app-password guide", "Google is detected from the address; sign-in uses an app password.", D, B],
  [98, "acc", "Settings: a section list per tab, each pane saves on its own", "", D, B],
  [99, "acc", "Default sender address", "", D, B],
  [100, "write", "Auto-save with crash recovery, on by default", "Writer, new messages and drafts survive a crash.", D, B],
  [101, "write", "Pick your reply colour; Slyy blue by default", "", D, B],
  [102, "read", "Fetch mail button; reply, reply all and forward shortcuts; text size", "⌘R, ⌘A, ⌘F; ⌘+ and ⌘− change the body size.", D, N],
  [103, "read", "Double-click opens the whole conversation in its own window", "", D, N],
  [104, "ai", "Ask Haven across all mail, with sources; Ask Haven sheet on iPhone", "", D, B],
  [105, "mac", "Apple Silicon only", "Smaller download from 0.4.0.", D, N],
  [106, "mac", "Slyy update window with plain release notes", "", D, N],
  [107, "q", "Shared test setup; manual calendar test on the real SOGo server", "", D, D],
  [108, "q", "Fix the 9 bugs from the code review", "Done 28 Nov, each with a regression test. See Code analytics.", D, D],
  [109, "q", "Remove the redundant code C1–C11", "Done 28 Nov: 474 lines of production code removed.", D, D],
  [110, "read", "… menu on every message: reply, reply all or forward just that one", "In conversations, the thread window and a single mail; a folded message loads first.", D, B],
  [111, "read", "Reply or forward only the selected text", "Selected text in a mail is all that is quoted; a forward of a selection carries no attachments.", D, B],
  [112, "read", "Double-click a message header opens just that message in its own window", "Also … → Open in New Window.", D, N],
  [120, "write", "Writer in its own resizable window on the Mac", "Each new message, reply or forward opens in a window you can resize; iPhone and iPad keep the sheet.", D, N],
  [121, "write", "Video link button as an icon; the link can be edited in the mail", "Only a full http(s) link is taken.", D, B],
  [122, "write", "Meeting invitation from the writer (calendar icon)", "Title, date, time, length and video link; To and Cc are invited, the event is saved in your calendar and the mail carries the invitation.", D, B],
  [123, "write", "Slyy-styled “Save as draft?” prompt; quieter footer", "Esc closes an untouched message without asking; the footer only shows the draft status or a warning if not encrypted.", D, B],
  [124, "vid", "Your own meeting link (e.g. vid.rocket.re-cloud.io/YourName) for mails, meetings and Meet now", "Only a server address: a private room per meeting, as before.", D, B],
  [130, "read", "Snooze & remind: dates in a mail (e.g. “back on Monday December 7th”) offer a reminder", "A quick on-device check of the text (English and German) shows “Back on …” under the header; pick the date and time, the mail is hidden until then and comes back unread with a notification. Also Snooze… in the … and list menus; kept on this device.", D, B],
  [131, "org", "Delete one message of a conversation; the rest stays open", "Delete in the reader, the Delete key and Move to Trash in the … menu act on the current message.", D, B],
  [132, "org", "⌘⌫ moves the current message to the Trash; ⌘Z brings it back", "", D, B],
  [133, "write", "Replies and forwards of HTML mail quote the HTML; the text part is clean text", "No code or styles in quotes; <br> is one line break, a paragraph two.", D, B],
  [134, "write", "Replies start with the cursor on the first line", "", D, N],
  [135, "write", "Reply from the first sender address of the domain the mail was sent to", "When no sender address matches exactly.", D, B],
  [136, "write", "Several addresses in To, Cc and Bcc add cleanly", "Chips flow and wrap; comma, semicolon, Return, a space after an address or a pasted list each make chips; backspace deletes the last chip.", D, B],
  [137, "read", "Search: sender/subject hits first, text mentions below, no doubles; stays put during refresh", "Searches as you type.", D, B],
  [138, "org", "Drag to a folder: a small tag instead of the whole row, the target folder highlighted; whole conversations move", "", D, N],
  [139, "write", "Edit as New Message: any mail as a new one to change and send again", "Right-click menu and the … menu.", D, B],
  [140, "read", "Click \u201cn unread\u201d to show only unread mail of the folder", "From the server, so older unread mail shows too; click again for all.", D, B],
'''
bl_js = bl_js.replace('  [88, "q", "Privacy-friendly crash reports", "", T, T, 3]', '  [88, "q", "Privacy-friendly crash reports", "", T, T, 3],' + new_items.rstrip().rstrip(','))
assert '[109,' in bl_js
bl_js = bl_js.replace('out.push(`<section>', 'out.push(`<section id="bl-${key}">')
bl_js = bl_js.replace('document.querySelectorAll(".seg button")', 'document.querySelectorAll("#backlog .seg button")')
bl_js = bl_js.replace('try { pf = localStorage', 'try { pf = localStorage').replace('"mailr.pf"', '"book.pf"').replace('"mailr.p1"', '"book.p1"')
bl_sections = re.search(r'const SECTIONS = \[(.*?)\];', bl_js, re.S).group(1)
bl_toc = re.findall(r'\["(\w+)", "([^"]+)"\]', bl_sections)

# ---------- analytics ----------
L = lambda n: json.load(open(A + n + '.json'))
tot = L('totals')['rows'][0]
commit = next(m['value'] for m in L('totals')['meta'] if m['label'] == 'Commit')
mods, rel, cov, covf, fns, sec, rev, cln = (L(n)['rows'] for n in ['modules', 'releases', 'coverage', 'coverage_files', 'functions', 'security', 'review', 'cleanup'])
f = lambda n: f'{n:,}'
def bars(rows, label, value, text, cls=lambda r: '', mx=None):
    mx = mx or max(value(r) for r in rows)
    out = ['<div class="bars">']
    for r in rows:
        out.append(f'<div class="bar-row {cls(r)}"><span class="bl-l">{esc(label(r))}</span><span class="bl-t"><i style="width:{value(r) / mx * 100:.1f}%"></i></span><span class="bl-v">{text(r)}</span></div>')
    return ''.join(out) + '</div>'
# line chart of releases
W, H, ml, mr, mt, mb = 720, 240, 40, 30, 12, 34
maxv = max(r['code'] for r in rel) * 1.08
step = (W - ml - mr) / (len(rel) - 1)
X = lambda i: ml + i * step
Y = lambda v: mt + (H - mt - mb) * (1 - v / maxv)
svg = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Lines of production code and tests at each of {len(rel)} releases, from {rel[0]["tag"]} ({f(rel[0]["code"])} code lines) to {rel[-1]["tag"]} ({f(rel[-1]["code"])})">']
for v in range(0, int(maxv) + 1, 2000):
    svg.append(f'<line x1="{ml}" x2="{W - mr}" y1="{Y(v):.1f}" y2="{Y(v):.1f}" class="grid"/><text x="{ml - 6}" y="{Y(v):.1f}" dy="0.32em" text-anchor="end" class="tick">{v // 1000}k</text>')
for i, r in enumerate(rel):
    if i % 2 == 0 or i == len(rel) - 1:
        svg.append(f'<text x="{X(i):.1f}" y="{H - 10}" text-anchor="middle" class="tick">{r["tag"]}</text>')
for k, c in (('code', 's1'), ('test', 's2')):
    pts = ' '.join(f'{X(i):.1f},{Y(r[k]):.1f}' for i, r in enumerate(rel))
    svg.append(f'<polyline points="{pts}" class="line {c}"/>')
    for i, r in enumerate(rel):
        svg.append(f'<circle cx="{X(i):.1f}" cy="{Y(r[k]):.1f}" r="3" class="dot {c}"><title>{r["tag"]} · {r["date"]} · {k} {f(r[k])}</title></circle>')
svg.append(f'<text x="{X(len(rel) - 1) - 4:.1f}" y="{Y(rel[-1]["code"]) - 10:.1f}" text-anchor="end" class="end">{f(rel[-1]["code"])}</text>')
svg.append(f'<text x="{X(len(rel) - 1) - 4:.1f}" y="{Y(rel[-1]["test"]) - 10:.1f}" text-anchor="end" class="end">{f(rel[-1]["test"])}</text></svg>')
def table(cols, rows, sev=None):
    h = ['<div class="scroll"><table><thead><tr>'] + [f'<th class="{"num" if n else ""}">{t}</th>' for t, k, n in cols] + ['</tr></thead><tbody>']
    for r in rows:
        h.append('<tr>')
        for t, k, n in cols:
            v = r[k]
            if k == sev:
                h.append(f'<td><span class="sev sev-{esc(str(v))}">{esc(str(v))}</span></td>')
            else:
                h.append(f'<td class="{"num" if n else ""}">{esc(str(v))}</td>')
        h.append('</tr>')
    return ''.join(h) + '</tbody></table></div>'
growth = rel[-1]['code'] / rel[0]['code']
an = f'''
<section id="analytics" class="part">
  <div class="part-head">
    <span class="eyebrow">Part 4 · Code analytics</span>
    <h2>Code analytics</h2>
    <p class="meta">Snapshot of commit {commit}, 28 Nov 2026, made by slyy-analytics (Tools/slyy-analytics in the repo). Rerun with <code>python3 -m slyy_analytics</code> (see Tools/slyy-analytics/README.md).</p>
  </div>
  <h3 id="an-summary">Summary</h3>
  <p class="lead">Slyy Mailr has {f(tot["code_lines"])} lines of production code and {f(tot["test_lines"])} lines of tests. The library's tests run {tot["coverage_percent"]}% of its code. The review found {tot["review_important"]} bugs worth fixing, and all are fixed. The cleanup of {tot["cleanup_items"]} pieces of redundant code is done: production code went from 12,013 to {f(tot["code_lines"])} lines.</p>
  <div class="tiles">
    <div class="tile"><span class="k">Production code</span><span class="v">{f(tot["code_lines"])}</span><span class="n">lines, without comments and blanks</span></div>
    <div class="tile"><span class="k">Tests</span><span class="v">{f(tot["test_lines"])}</span><span class="n">{tot["test_ratio"]} lines per line of code</span></div>
    <div class="tile"><span class="k">Library coverage</span><span class="v">{tot["coverage_percent"]}%</span><span class="n">the app's views aren't measured</span></div>
    <div class="tile"><span class="k">Review findings</span><span class="v">{tot["review_important"]}</span><span class="n">important, all fixed; {tot["review_minor"]} minor open</span></div>
    <div class="tile"><span class="k">Cleanup</span><span class="v">{tot["cleanup_items"]}</span><span class="n">items, all done</span></div>
    <div class="tile"><span class="k">Functions</span><span class="v">{tot["functions"]}</span><span class="n">median {tot["median_function_lines"]} lines; {tot["long_functions"]} over 60</span></div>
  </div>
  <h3 id="an-growth">Growth per release</h3>
  <p class="lead">Code grew {growth:.1f}× from {rel[0]["tag"]} to {rel[-1]["tag"]}, across {len(rel)} releases.</p>
  <div class="legend"><span><i class="sw s1"></i>Production code</span><span><i class="sw s2"></i>Tests</span></div>
  <div class="chart scroll">{''.join(svg)}</div>
  <div class="two">
    <div><h3 id="an-modules">Code by module</h3>{bars(mods, lambda r: r["module"], lambda r: r["code"], lambda r: f(r["code"]), lambda r: "k-" + r["kind"])}</div>
    <div><h3 id="an-coverage">Library coverage</h3>{bars(sorted(cov, key=lambda r: -r["percent"]), lambda r: r["module"].replace("Library · ", ""), lambda r: r["percent"], lambda r: f'{r["percent"]}%', lambda r: "low" if r["percent"] < 60 else "", 100)}
      <p class="note">Least covered: {", ".join(f'{r["file"]} {r["percent"]}%' for r in covf[:4])}.</p></div>
  </div>
  <h3 id="an-review">Code review findings</h3>
  <p class="lead">Found by reading the code on 28 Nov. The 9 important ones are fixed, each with a regression test (28 Nov); the minor one is still open.</p>
  {table([("#", "id", 0), ("Severity", "severity", 0), ("Area", "area", 0), ("Problem", "summary", 0), ("When it happened", "scenario", 0), ("File", "file", 0), ("Status", "status", 0)], rev, "severity")}
  <h3 id="an-cleanup">Cleanup backlog</h3>
  <p class="lead">Each item is marked in the code as <code>// CLEANUP(Cn)</code> and listed in <code>docs/CLEANUP.md</code>. All done on 28 Nov (commits 131b068 to b886029); the build passed.</p>
  {table([("#", "id", 0), ("Action", "action", 0), ("What", "summary", 0), ("Fix", "fix", 0), ("Files", "files", 0), ("~Lines", "lines", 1)], cln)}
  <h3 id="an-security">Security and dependencies</h3>
  <p class="lead">No real secrets in the code; the two hits are test placeholders.</p>
  {table([("Level", "severity", 0), ("Area", "area", 0), ("Item", "item", 0), ("What it means", "detail", 0)], sec, "severity")}
  <h3 id="an-functions">Longest functions</h3>
  {table([("Function", "function", 0), ("File", "file", 0), ("Line", "line", 1), ("Lines", "lines", 1)], fns)}
</section>'''

# ---------- ToC ----------
def li(href, text, sub=None, cls=''):
    s = f'<li class="{cls}"><a href="#{href}">{esc(text)}</a>'
    if sub:
        s += '<ol>' + ''.join(f'<li class="{"sub2" if h.startswith("wf-") and h not in ("wf-desktop", "wf-agent", "wf-mobile") else ""}"><a href="#{h}">{esc(t)}</a></li>' for h, t in sub) + '</ol>'
    return s + '</li>'
toc = '<ol class="toc-list">' + ''.join([
    li('spec', 'Spec', [('spec-overview', 'Overview'), ('spec-architecture', 'Architecture'), ('spec-mail', 'Mail'), ('spec-calendar', 'Calendar'), ('spec-video', 'Video calls'), ('spec-nonfunctional', 'Contacts, security, targets'), ('spec-milestones', 'Milestones and open questions')]),
    li('wireframes', 'Wireframes', [('wf-desktop', 'Mac app')] + [(i, t) for i, t in wf_toc['desktop']] + [('wf-agent', 'Ask Haven proposal')] + wf_toc['agent'] + [('wf-mobile', 'iPhone')] + wf_toc['mobile']),
    li('backlog', 'Backlog', [('bl-' + k, n) for k, n in bl_toc]),
    li('analytics', 'Code analytics', [('an-summary', 'Summary'), ('an-growth', 'Growth per release'), ('an-modules', 'Code by module'), ('an-coverage', 'Coverage'), ('an-review', 'Review findings'), ('an-cleanup', 'Cleanup backlog'), ('an-security', 'Security and dependencies'), ('an-functions', 'Longest functions')]),
]) + '</ol>'
# mark wireframe sub-sub entries

tpl = open('page.tpl.html').read()
out = (tpl.replace('%%TOC%%', toc).replace('%%SPEC%%', open('spec.html').read()).replace('%%WF%%', '\n'.join(wf_html))
       .replace('%%WFDEFS%%', wf_defs).replace('%%BLJS%%', bl_js).replace('%%AN%%', an))
os.makedirs(os.path.join(ROOT, 'build', 'project-book'), exist_ok=True)
OUT = os.path.join(ROOT, 'build', 'project-book', 'mailr-book.html')
open(OUT, 'w').write(out)
print(OUT)
print(len(out), len(boards), 'boards')
