#!/usr/bin/env python3
"""Publish the KBAuthFix module source + workflow in ONE commit, then build it.

Usage:
  python publish_kbauthfix.py publish     # upload files + dispatch workflow
  python publish_kbauthfix.py status      # show latest runs
  python publish_kbauthfix.py download    # fetch KBAuthFix.zip artifact -> APK
"""
import os, sys, json, base64, time, re, urllib.request, urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOKEN_FILE = Path(r'C:/Users/yan/AppData/Local/Temp/gh_token_new.txt')
os.environ['GH_TOKEN'] = TOKEN_FILE.read_text().strip()
os.environ['GH_PROXY'] = 'none'
sys.path.insert(0, str(ROOT / 'scripts'))
import github_api as g

REPO = 'kayn0922/sm8250-A17-Kernel'
WF = 'build-kbauthfix.yml'
OUT_APK = ROOT.parent.parent / 'post-unhook-20261110' / 'round2' / 'KBAuthFix.apk'


def default_branch():
    code, d = g.http('GET', '/repos/' + REPO)
    if code != 200:
        sys.exit('repo lookup failed: %s %s' % (code, d))
    return d['default_branch']


def collect():
    out = []
    for p in sorted((ROOT / 'kbauthfix').rglob('*')):
        if p.is_file() and '__pycache__' not in p.parts and p.suffix != '.pyc':
            out.append((p.relative_to(ROOT).as_posix(), p.read_bytes()))
    wf = ROOT / '.github' / 'workflows' / WF
    out.append(('.github/workflows/' + WF, wf.read_bytes()))
    return out


def publish():
    branch = default_branch()
    code, ref = g.http('GET', '/repos/%s/git/ref/heads/%s' % (REPO, branch))
    if code != 200:
        sys.exit('ref failed: %s %s' % (code, ref))
    base_commit = ref['object']['sha']
    code, cm = g.http('GET', '/repos/%s/git/commits/%s' % (REPO, base_commit))
    base_tree = cm['tree']['sha']
    print('branch=%s base=%s tree=%s' % (branch, base_commit[:8], base_tree[:8]))

    entries = []
    for rel, raw in collect():
        if b'\r\n' in raw:
            raw = raw.replace(b'\r\n', b'\n')
        code, blob = g.http('POST', '/repos/%s/git/blobs' % REPO,
                            {'content': base64.b64encode(raw).decode('ascii'),
                             'encoding': 'base64'})
        if code not in (200, 201):
            sys.exit('blob failed %s: %s %s' % (rel, code, blob))
        entries.append({'path': rel,
                        'mode': '100755' if rel.endswith('.sh') else '100644',
                        'type': 'blob', 'sha': blob['sha']})
        print('  blob %-62s %s' % (rel, blob['sha'][:8]))

    code, tree = g.http('POST', '/repos/%s/git/trees' % REPO,
                        {'base_tree': base_tree, 'tree': entries})
    if code not in (200, 201):
        sys.exit('tree failed: %s %s' % (code, tree))
    code, commit = g.http('POST', '/repos/%s/git/commits' % REPO,
                          {'message': 'Add KBAuthFix Xposed module build',
                           'tree': tree['sha'], 'parents': [base_commit]})
    if code not in (200, 201):
        sys.exit('commit failed: %s %s' % (code, commit))
    code, upd = g.http('PATCH', '/repos/%s/git/refs/heads/%s' % (REPO, branch),
                       {'sha': commit['sha']})
    if code != 200:
        sys.exit('ref update failed: %s %s' % (code, upd))
    print('pushed commit', commit['sha'][:8])

    # Wait for GitHub to register the new workflow, then dispatch.
    for i in range(12):
        code, d = g.http('GET', '/repos/%s/actions/workflows/%s' % (REPO, WF))
        if code == 200:
            break
        time.sleep(3)
    else:
        sys.exit('workflow not registered')
    code, d = g.http('POST', '/repos/%s/actions/workflows/%s/dispatches' % (REPO, WF),
                     {'ref': branch})
    print('dispatch HTTP %s (204 = accepted)' % code, '' if code in (204, 201) else d)


def latest_run():
    code, d = g.http('GET', '/repos/%s/actions/runs?per_page=8' % REPO)
    if code != 200:
        sys.exit('runs failed: %s %s' % (code, d))
    for r in d.get('workflow_runs', []):
        if WF in (r.get('path') or ''):
            print('run %s %s %s %s' % (r['id'], r['status'],
                                       r.get('conclusion') or '-', r['html_url']))
            return r
    print('no KBAuthFix run yet')
    return None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def download():
    r = latest_run()
    if not r or r['status'] != 'completed':
        sys.exit('build not finished yet')
    if r.get('conclusion') != 'success':
        sys.exit('build failed: %s' % r.get('conclusion'))
    code, d = g.http('GET', '/repos/%s/actions/runs/%s/artifacts' % (REPO, r['id']))
    if code != 200:
        sys.exit('artifacts failed: %s %s' % (code, d))
    arts = [a for a in d.get('artifacts', []) if a['name'] == 'KBAuthFix' and not a['expired']]
    if not arts:
        sys.exit('no KBAuthFix artifact')
    url = arts[0]['archive_download_url']
    print('artifact', arts[0]['name'], arts[0].get('size') or arts[0].get('size_in_bytes') or '?', 'bytes')
    op = urllib.request.build_opener(NoRedirect)
    req = urllib.request.Request(url, headers={
        'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
        'User-Agent': 'kbauthfix'})
    try:
        op.open(req, timeout=90)
        sys.exit('expected a redirect')
    except urllib.error.HTTPError as e:
        if e.code not in (301, 302, 307):
            sys.exit('artifact error %s %s' % (e.code, e.read()[:300]))
        loc = e.headers.get('Location')
    # The signed URL must be fetched WITHOUT the Authorization header (401 otherwise).
    with urllib.request.urlopen(loc, timeout=300) as resp:
        raw = resp.read()
    import io, zipfile
    z = zipfile.ZipFile(io.BytesIO(raw))
    names = z.namelist()
    apk = [n for n in names if n.endswith('.apk')]
    if not apk:
        sys.exit('artifact has no apk: %s' % names)
    OUT_APK.parent.mkdir(parents=True, exist_ok=True)
    OUT_APK.write_bytes(z.read(apk[0]))
    print('saved', OUT_APK, OUT_APK.stat().st_size, 'bytes')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    {'publish': publish, 'status': lambda: latest_run(), 'download': download}[cmd]()
