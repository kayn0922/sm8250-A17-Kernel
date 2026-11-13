#!/usr/bin/env python3
"""GitHub REST driver for the sm8250 A17 kernel builder.

All operations go through api.github.com (usable even when github.com itself
is blocked). Set GH_TOKEN before running; on this machine an HTTP proxy at
127.0.0.1:10808 is used by default (override with GH_PROXY=none).

Commands:
  publish    Create <you>/sm8250-A17-Kernel and upload this project
  dispatch   Trigger "Build A17 Kernel (SukiSU)"
  status     Show recent workflow runs
  download   Fetch the newest Kernel_*.zip Release asset
"""
import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPO_NAME = 'sm8250-A17-Kernel'
WORKFLOW_PATH = '.github/workflows/build-a17-kernel.yml'
API = 'https://api.github.com'
BRANCH = 'main'

TOKEN = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
if not TOKEN:
    for p in (Path(os.environ.get('TEMP', '/tmp')) / 'gh_token_new.txt',
              Path('C:/Users/yan/AppData/Local/Temp/gh_token_new.txt')):
        if p.exists():
            TOKEN = p.read_text(encoding='utf-8').strip()
            break
if not TOKEN:
    sys.exit('ERROR: set GH_TOKEN (token with repo + workflow scopes)')

_proxy = os.environ.get('GH_PROXY', 'http://127.0.0.1:10808')
_handler = urllib.request.ProxyHandler({'http': _proxy, 'https': _proxy}) if _proxy not in ('', 'none') else None
_opener = urllib.request.build_opener(_handler) if _handler else urllib.request.build_opener()


def http(method, path, body=None, accept='application/vnd.github+json', timeout=90):
    url = path if path.startswith('http') else API + path
    headers = {'Authorization': 'Bearer ' + TOKEN, 'Accept': accept,
               'User-Agent': 'sm8250-a17-kernel-builder'}
    data = None
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    last = None
    for attempt in range(6):
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with _opener.open(req, timeout=timeout) as r:
                raw = r.read()
                try:
                    return r.status, json.loads(raw)
                except ValueError:
                    return r.status, raw
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, raw.decode('utf-8', 'replace')
        except Exception as e:  # transient proxy/network errors
            last = e
            time.sleep(2 + attempt * 2)
    raise SystemExit('network failed after 6 attempts: %s' % last)


def owner():
    code, d = http('GET', '/user')
    if code != 200:
        sys.exit('cannot resolve account: %s %s' % (code, d))
    return d['login']


def full(me):
    return '%s/%s' % (me, REPO_NAME)


def upload_tree(repo):
    files = [p for p in ROOT.rglob('*') if p.is_file()
             and '.git' not in p.parts and '__pycache__' not in p.parts
             and p.suffix not in ('.pyc', '.zip', '.img')]
    uploaded = 0
    for p in sorted(files):
        rel = p.relative_to(ROOT).as_posix()
        content = base64.b64encode(p.read_bytes()).decode('ascii')
        code, cur = http('GET', '/repos/%s/contents/%s?ref=%s' % (repo, rel, BRANCH))
        body = {'message': 'Add/update %s' % rel, 'content': content, 'branch': BRANCH}
        if code == 200 and isinstance(cur, dict) and cur.get('sha'):
            body['sha'] = cur['sha']
        code, res = http('PUT', '/repos/%s/contents/%s' % (repo, rel), body)
        if code not in (200, 201):
            sys.exit('upload failed for %s: %s %s' % (rel, code, res))
        uploaded += 1
        print('  %-55s %s' % (rel, 'updated' if 'sha' in body else 'created'))
    print('uploaded %d files' % uploaded)


def cmd_publish(args):
    me = owner()
    repo = full(me)
    code, d = http('GET', '/repos/' + repo)
    if code == 404:
        code, d = http('POST', '/user/repos', {
            'name': REPO_NAME,
            'description': 'A17-ready sm8250 kernel (elish/enuma/dagu) with ReSukiSU + SuSFS',
            'private': False, 'has_issues': True, 'has_wiki': False,
            'has_projects': False, 'auto_init': True, 'has_actions': True,
        })
        if code not in (201, 202):
            sys.exit('create repo failed: %s %s' % (code, d))
        print('created repo:', d.get('html_url'))
        time.sleep(4)
    elif code != 200:
        sys.exit('repo lookup failed: %s %s' % (code, d))
    else:
        print('repo exists:', d.get('html_url'))
    upload_tree(repo)
    print('DONE: https://github.com/' + repo)


def find_workflow(repo):
    for _ in range(10):
        code, d = http('GET', '/repos/%s/actions/workflows' % repo)
        if code == 200:
            for w in d.get('workflows', []):
                if w['path'] == WORKFLOW_PATH:
                    return w['id']
        time.sleep(3)
    sys.exit('workflow %s not registered yet; check the Actions tab' % WORKFLOW_PATH)


def cmd_dispatch(args):
    me = owner()
    repo = full(me)
    wid = find_workflow(repo)
    inputs = {'device': args.device, 'ksu': args.ksu,
              'target_system': args.system, 'gps_dts_fix': args.gps}
    code, d = http('POST', '/repos/%s/actions/workflows/%s/dispatches' % (repo, wid),
                   {'ref': BRANCH, 'inputs': inputs})
    print('dispatch HTTP %s (204 = accepted)' % code, '' if code in (204, 201) else d)
    if code not in (204, 201, 200):
        sys.exit('dispatch failed')
    time.sleep(6)
    cmd_status(args)


def cmd_status(args):
    me = owner()
    repo = full(me)
    code, d = http('GET', '/repos/%s/actions/runs?per_page=6' % repo)
    if code != 200:
        sys.exit('status failed: %s %s' % (code, d))
    runs = d.get('workflow_runs', [])
    print('recent runs for', repo)
    for r in runs:
        print('  %-12s %-12s %-12s %s  %s' % (
            r['id'], r['status'], r.get('conclusion') or '-',
            r['created_at'], r['html_url']))
    if not runs:
        print('  (none yet)')


def cmd_download(args):
    me = owner()
    repo = full(me)
    code, d = http('GET', '/repos/%s/releases?per_page=10' % repo)
    if code != 200:
        sys.exit('releases failed: %s %s' % (code, d))
    for rel in d:
        for a in rel.get('assets', []):
            if a['name'].startswith('Kernel_') and a['name'].endswith('.zip'):
                dest = ROOT.parent / a['name']
                print('downloading', a['name'], a['size'], 'bytes')
                code, raw = http('GET', a['url'], accept='application/octet-stream', timeout=600)
                if isinstance(raw, bytes) and raw[:2] == b'PK':
                    dest.write_bytes(raw)
                else:
                    # assets API redirects to a signed object URL
                    req = urllib.request.Request(a['browser_download_url'],
                                                 headers={'User-Agent': 'sm8250-a17-kernel-builder'})
                    with _opener.open(req, timeout=600) as r:
                        dest.write_bytes(r.read())
                print('saved:', dest, dest.stat().st_size, 'bytes')
                return
    print('no Kernel_*.zip release asset yet; run `status` first')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('publish')
    p = sub.add_parser('dispatch')
    p.add_argument('--device', default='enuma', choices=['elish', 'enuma', 'dagu'])
    p.add_argument('--ksu', default='ksu', choices=['ksu', 'rksu', 'noksu'])
    p.add_argument('--system', default='miui', choices=['miui', 'aosp', 'both'])
    p.add_argument('--gps', default='none', choices=['none', 'dagu-minimal-node'])
    sub.add_parser('status')
    sub.add_parser('download')
    args = ap.parse_args()
    {'publish': cmd_publish, 'dispatch': cmd_dispatch,
     'status': cmd_status, 'download': cmd_download}[args.cmd](args)


if __name__ == '__main__':
    main()
