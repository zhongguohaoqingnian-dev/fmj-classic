#!/usr/bin/env python3
"""Build the standalone Windows and macOS downloads using installed Godot templates."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = '0.6.2'


def run(command):
    result = subprocess.run([str(x) for x in command], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode or 'SCRIPT ERROR:' in result.stdout or 'ERROR:' in result.stdout:
        print(result.stdout)
        raise SystemExit(result.returncode or 1)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['all', 'Windows', 'macOS'], default='all')
    parser.add_argument('--godot', default=os.environ.get('GODOT_BIN', shutil.which('godot') or '/Applications/Godot.app/Contents/MacOS/Godot'))
    args = parser.parse_args()
    version = run([args.godot, '--version']).strip()
    if version != '4.7.2.stable.official.ed1daf0bf':
        raise SystemExit('Install the locked Godot 4.7.2 official editor and its matching export templates.')
    if not (ROOT / 'data/game/classic.json').is_file():
        raise SystemExit('Missing bundled game data.')
    log = run([args.godot, '--headless', '--editor', '--path', ROOT, '--import', '--quit'])
    builds = ROOT / 'builds'
    builds.mkdir(exist_ok=True)
    (builds / 'import.log').write_text(log)
    platforms = ['Windows', 'macOS'] if args.platform == 'all' else [args.platform]
    for platform in platforms:
        stage = builds / platform
        stage.mkdir(exist_ok=True)
        target = stage / ('FMJClassic.exe' if platform == 'Windows' else 'FMJClassic.zip')
        log = run([args.godot, '--headless', '--path', ROOT, '--export-release', platform, target])
        (builds / (platform + '-export.log')).write_text(log)
        archive = builds / f'FMJClassic-{VERSION}-{platform}.zip'
        if platform == 'macOS':
            shutil.copyfile(target, archive)
            with zipfile.ZipFile(archive, 'a', zipfile.ZIP_DEFLATED) as out:
                for name in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md']:
                    out.write(ROOT / name, name)
        else:
            for name in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'README.md']:
                shutil.copyfile(ROOT / name, stage / name)
            with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED) as out:
                for file in sorted(stage.rglob('*')):
                    if file.is_file(): out.write(file, 'FMJClassic/' + file.relative_to(stage).as_posix())
        print(f'{archive.name}: {archive.stat().st_size:,} bytes')
    archives = sorted(builds.glob(f'FMJClassic-{VERSION}-*.zip'))
    (builds / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in archives))


if __name__ == '__main__':
    main()
