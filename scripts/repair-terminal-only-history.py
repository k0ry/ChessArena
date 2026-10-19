#!/usr/bin/env python3
"""One-time, reversible correction of two verified 2026-10-18 technical forfeits.

Dry run by default. --apply requires ChessArena to be closed. Original archives
are never changed. The write-ahead report and before/after snapshots make a
partial run resumable and a completed run idempotent.
"""
import argparse
import copy
import hashlib
import json
import pathlib
import plistlib
import subprocess

DOMAIN = 'com.chessarena.broadcast'
SCORE_KEY = 'seriesScore.DeepSeek|Gemini'
ROUND = '9B89936B-6528-4EDE-B66B-8FB30E481F03'
FEN = 'r1b1k2r/1pqnbppp/p2ppn2/6B1/3NPP2/2N2Q2/PPP3PP/2KR1B1R w kq - 5 10'
OLD = {'games': 2, 'whiteHalfPoints': 0, 'blackHalfPoints': 4}
NEW = {'games': 0, 'whiteHalfPoints': 0, 'blackHalfPoints': 0}
ARCHIVES = [
    ('2026-10-18T10-41-38Z-9E1580F5-FFC5-4210-8D72-7639AAEB8C28-18E13878-4776-46CA-BDBA-3D3287258F78',
     '173536e6a7570e9d1ee260cb9023f54ca273ffeb3cdecaa03a8f887dcc1e2592',
     'r2q1rk1/1p1nbppp/p2pbn2/4p3/4P3/1NN1BP2/PPPQ2PP/2KR1B1R w - - 5 11', 40),
    ('2026-10-18T11-27-23Z-96E0A6B1-97E0-4F85-BCF7-35F6EC149549-915ADB6D-B12D-41DE-9083-CA37FBA2AB45',
     '947cd549eff1902a5f05e6083b2064ba5be833d5c143c4a1ffe89635931ca0c4',
     'r2q1rk1/3nbppp/p2pb3/4p1Pn/1p2P3/1N2BP2/PPPQN2P/2KR1B1R w - - 2 14', 36),
]

def correction(state, score):
    result = copy.deepcopy(state)
    game = state.get('game', {})
    if (state['series'].get('roundID') != ROUND or state['series'].get('running')
            or game.get('referee', {}).get('position') != FEN
            or state.get('white', {}).get('model') != 'deepseek-v4-pro'):
        raise ValueError('Session identity/position changed; manual reconciliation required')
    if state['series']['score'] != OLD or score != OLD:
        raise ValueError('Totals differ from the two verified results; no automatic subtraction')
    result['series']['score'] = copy.deepcopy(NEW)
    quarantined = []
    for location, owner in [('gameMemory', result), ('game.gameMemory', result['game'])]:
        memory = owner.get('gameMemory', {})
        kept = []
        for entry in memory.get('entries', []):
            deepseek = (entry.get('endpoint'), entry.get('model'), entry.get('side')) == ('deepseek:https://api.deepseek.com', 'deepseek-v4-pro', 'white')
            argon = (entry.get('endpoint'), entry.get('model'), entry.get('side')) == ('geminiCLI:local-cli://antigravity', 'gemini-4-argon-high', 'black')
            advice = entry.get('advice', '')
            contaminated = (deepseek and 'трёх нелегальных ответов' in advice) or (argon and 'forfeit via invalid replies after 13...Nh5' in advice)
            if contaminated:
                quarantined.append({'location': location, 'entry': entry})
            else:
                kept.append(entry)
        if 'entries' in memory:
            memory['entries'] = kept
    return result, quarantined

def write_json(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temp.replace(path)

def preferences():
    data = subprocess.check_output(['defaults', 'export', DOMAIN, '-'])
    return plistlib.loads(data)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    home = pathlib.Path.home()
    session = home / 'Library/Application Support/ChessArena/session.json'
    folder = session.parent / 'repairs/2026-10-18-terminal-only'
    report_path = folder / 'report.json'
    evidence = []
    for name, expected_hash, fen, count in ARCHIVES:
        path = home / 'Documents/ChessArena' / name / 'game.pgn'
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected_hash:
            raise ValueError('Archive differs from verified evidence: ' + name)
        evidence.append({'archive': str(path), 'sha256': expected_hash, 'originalResult': '0-1',
                         'correctedResult': '*', 'fen': fen, 'legalMoves': count,
                         'reason': 'Nonterminal board; legacy three-error forfeit', 'providerTrigger': 'unknown'})
    if report_path.exists():
        report = json.loads(report_path.read_text())
        if report['status'] == 'applied':
            print(json.dumps({'status': 'already-applied', 'report': str(report_path)})); return
    else:
        original = session.read_bytes()
        prefs = preferences()
        raw_score = prefs[SCORE_KEY]
        state, quarantined = correction(json.loads(original), json.loads(raw_score))
        report = {'status': 'prepared', 'pair': ['deepseek-v4-pro', 'gemini-4-argon-high'],
                  'scoreKey': SCORE_KEY, 'before': OLD, 'after': NEW, 'continuingRound': ROUND,
                  'positionPreserved': FEN, 'evidence': evidence, 'quarantined': quarantined,
                  'note': 'Original PGN, commentary and video remain unchanged. No LC0 preference was modified.'}
        if not args.apply:
            print(json.dumps({**report, 'quarantined': [q['location'] + ':' + q['entry']['model'] for q in quarantined]}, ensure_ascii=False, indent=2)); return
        if subprocess.run(['pgrep', '-x', 'ChessArena'], capture_output=True).returncode == 0:
            raise RuntimeError('Close ChessArena before applying the correction')
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'session.before.json').write_bytes(original)
        (folder / 'score.before.json').write_bytes(raw_score)
        write_json(folder / 'session.after.json', state)
        write_json(report_path, report)
    if not args.apply:
        print(json.dumps({'status': 'prepared', 'report': str(report_path)})); return
    if subprocess.run(['pgrep', '-x', 'ChessArena'], capture_output=True).returncode == 0:
        raise RuntimeError('Close ChessArena before applying the correction')
    before = (folder / 'session.before.json').read_bytes()
    after = (folder / 'session.after.json').read_bytes()
    if session.read_bytes() not in (before, after):
        raise ValueError('Session changed since preparation; refusing overwrite')
    current = preferences()
    if json.loads(current[SCORE_KEY]) not in (OLD, NEW):
        raise ValueError('Score changed since preparation; refusing overwrite')
    tmp = session.with_suffix('.repair.tmp'); tmp.write_bytes(after); tmp.replace(session)
    score_data = json.dumps(NEW, separators=(',', ':')).encode()
    subprocess.run(['defaults', 'write', DOMAIN, SCORE_KEY, '-data', score_data.hex()], check=True)
    verified = preferences()
    if json.loads(verified[SCORE_KEY]) != NEW:
        raise ValueError('Preference readback failed')
    if any(verified.get(k) != v for k, v in current.items() if k.startswith('seriesScore.') and k != SCORE_KEY):
        raise ValueError('Unrelated score changed during repair; inspect report')
    if session.read_bytes() != after:
        raise ValueError('Session readback failed')
    report['status'] = 'applied'; write_json(report_path, report)
    print(json.dumps({'status': 'applied', 'report': str(report_path), 'score': NEW}, ensure_ascii=False))

if __name__ == '__main__':
    main()
