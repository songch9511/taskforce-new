#!/usr/bin/env python3
"""Build, sign, and run a watched native Mac app without replacing /Applications."""
import argparse
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
IGNORED = {'.git', '.build', 'build', 'DerivedData', 'node_modules', '.swiftpm'}
EXTENSIONS = {'.swift', '.plist', '.xcconfig', '.pbxproj', '.xcscheme', '.yml', '.entitlements', '.json', '.png', '.pdf', '.svg'}


def snapshot(root, xcconfig, excluded):
    result = {}
    excluded = excluded.resolve()
    for directory, names, files in os.walk(root):
        names[:] = [n for n in names if n not in IGNORED and not (Path(directory) / n).is_symlink()
                    and (Path(directory) / n).resolve() != excluded]
        for name in files:
            path = Path(directory) / name
            if path.suffix in EXTENSIONS or name == 'Package.resolved':
                try:
                    stat = path.stat()
                    result[str(path)] = [stat.st_mtime_ns, stat.st_size]
                except FileNotFoundError:
                    pass  # A save can replace a file between enumeration and stat.
    try:
        stat = xcconfig.stat()
        result[str(xcconfig)] = [stat.st_mtime_ns, stat.st_size]
    except FileNotFoundError:
        pass
    return result


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def run(command, log, cwd=ROOT):
    process = subprocess.Popen(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT)
    try:
        if process.wait() != 0:
            raise RuntimeError('Command failed: ' + command[0])
    finally:
        stop(process)


def prepare(args, control):
    """Never mutate the currently running bundle while compiling or signing."""
    log_path = control / 'build.log'
    with log_path.open('w') as log:
        run(['xcodebuild', 'build', '-jobs', '2', '-project', 'apple/Taskforce.xcodeproj',
             '-scheme', 'Taskforce', '-configuration', 'Release', '-destination', 'platform=macOS',
             '-derivedDataPath', str(args.derived_data), '-disableAutomaticPackageResolution',
             '-xcconfig', str(args.xcconfig), 'CODE_SIGNING_ALLOWED=NO', 'ONLY_ACTIVE_ARCH=YES',
             'SWIFT_OPTIMIZATION_LEVEL=-Onone', 'SWIFT_COMPILATION_MODE=incremental'], log)
        source = args.derived_data / 'Build/Products/Release/Taskforce.app'
        folder = Path(tempfile.mkdtemp(prefix='run-', dir=control))
        app = folder / 'Taskforce.app'
        try:
            run(['ditto', str(source), str(app)], log)
            info_path = app / 'Contents/Info.plist'
            info = plistlib.loads(info_path.read_bytes())
            reference_info = plistlib.loads((args.reference_app / 'Contents/Info.plist').read_bytes())
            if info['CFBundleIdentifier'] != reference_info['CFBundleIdentifier']:
                raise RuntimeError('Built app and reference app bundle IDs differ')
            info['TaskforceKeychainAccessGroup'] = reference_info['TaskforceKeychainAccessGroup']
            info['TaskforceSourceCommit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() + '+dev'
            info['TaskforceBuildTimeUTC'] = datetime.now(timezone.utc).isoformat()
            info_path.write_bytes(plistlib.dumps(info))
            shutil.copyfile(args.reference_app / 'Contents/embedded.provisionprofile', app / 'Contents/embedded.provisionprofile')
            entitlements = folder / 'entitlements.plist'
            with entitlements.open('wb') as output:
                subprocess.run(['codesign', '-d', '--entitlements', ':-', str(args.reference_app)],
                               stdout=output, stderr=log, check=True)
            plistlib.loads(entitlements.read_bytes())
            targets = {p.resolve() for p in app.rglob('*') if not p.is_symlink()
                       and p.suffix in {'.app', '.framework', '.xpc', '.dylib'}}
            for target in sorted(targets, key=lambda p: len(p.parts), reverse=True):
                run(['codesign', '--force', '--sign', args.signing_identity, '--timestamp=none',
                     '--options', 'runtime', str(target)], log)
            run(['codesign', '--force', '--sign', args.signing_identity, '--timestamp=none',
                 '--options', 'runtime', '--entitlements', str(entitlements), str(app)], log)
            run(['codesign', '--verify', '--deep', '--strict', str(app)], log)
            executable = app / 'Contents/MacOS' / info['CFBundleExecutable']
            if not executable.is_file():
                raise RuntimeError('Built app executable is missing')
            return folder, executable
        except BaseException:
            shutil.rmtree(folder)
            raise


def write_state(control, status, child=None, executable=None):
    temporary = control / 'state.tmp'
    temporary.write_text(json.dumps({'status': status, 'watcherPID': os.getpid(),
                                    'appPID': child.pid if child and child.poll() is None else None,
                                    'executable': str(executable) if executable else None,
                                    'updatedAt': time.time()}, indent=2) + '\n')
    temporary.replace(control / 'state.json')


def publish_ready(control, executable, source_snapshot):
    temporary = control / 'ready.tmp'
    temporary.write_text(json.dumps({'executable': str(executable), 'snapshot': source_snapshot}) + '\n')
    temporary.replace(control / 'ready.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xcconfig', required=True, type=Path)
    parser.add_argument('--derived-data', required=True, type=Path)
    parser.add_argument('--signing-identity', required=True)
    parser.add_argument('--reference-app', required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--once', action='store_true', help='Build and run once, without watching')
    mode.add_argument('--watch', action='store_true', help='Watch source changes (default)')
    mode.add_argument('--build-only', action='store_true', help='Publish a signed ready bundle without launching')
    parser.add_argument('--launch-ready', action='store_true', help='Launch the previously published bundle before watching')
    args = parser.parse_args()
    if args.launch_ready and (args.build_only or args.once):
        parser.error('--launch-ready is only available in watch mode')
    args.xcconfig = args.xcconfig.expanduser().resolve(strict=True)
    args.reference_app = args.reference_app.expanduser().resolve(strict=True)
    args.derived_data = args.derived_data.expanduser().resolve()
    if args.reference_app == args.derived_data or args.reference_app in args.derived_data.parents:
        parser.error('Derived data must be outside the reference app')
    control = args.derived_data / 'dev-loop'
    control.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(control, 0o700)
    lock = (control / 'watcher.lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error('A watcher already owns this derived-data directory')
    app_environment = dict(os.environ, TASKFORCE_DEV_KEEP_PANELS_OPEN='1')
    child = None
    folder = executable = None
    observed = None
    final_status = 'stopped'
    print('Native dev loop. Build log: ' + str(control / 'build.log'), flush=True)
    print('Quit the installed Taskforce before starting this app. Ctrl-C stops only this development process.', flush=True)
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if args.launch_ready:
            ready = json.loads((control / 'ready.json').read_text())
            executable = Path(ready['executable']).resolve(strict=True)
            folder = executable.parents[3]
            if folder.parent != control or not folder.name.startswith('run-'):
                raise RuntimeError('Ready bundle is outside this development directory')
            with (control / 'build.log').open('a') as log:
                run(['codesign', '--verify', '--deep', '--strict', str(executable.parents[2])], log)
            child = subprocess.Popen([str(executable)], cwd=ROOT, env=app_environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(1)
            if child.poll() is not None:
                raise RuntimeError('Ready app exited during startup; close the installed app before retrying')
            observed = ready['snapshot']
            write_state(control, 'running', child, executable)
            print('Signed ready app launched; watching sources.', flush=True)
        while True:
            current = snapshot(ROOT / 'apple', args.xcconfig, args.derived_data)
            if current != observed:
                time.sleep(0.75)
                if snapshot(ROOT / 'apple', args.xcconfig, args.derived_data) != current:
                    continue
                observed = current
                write_state(control, 'building', child, executable)
                print('Building saved changes…', flush=True)
                try:
                    candidate_folder, candidate = prepare(args, control)
                except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
                    write_state(control, 'build-failed', child, executable)
                    print('Build/sign failed; running app kept. See build.log. ' + str(error), flush=True)
                    if args.once or args.build_only:
                        return 1
                    continue
                if args.build_only:
                    publish_ready(control, candidate, current)
                    final_status = 'ready'
                    write_state(control, 'ready', executable=candidate)
                    print('Signed app ready. Use --launch-ready --watch to run it.', flush=True)
                    return 0
                # Signing succeeded: only now replace the process this watcher owns.
                stop(child)
                old_folder, old_executable = folder, executable
                try:
                    child = subprocess.Popen([str(candidate)], cwd=ROOT, env=app_environment,
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    time.sleep(1)
                    if child.poll() is not None:
                        raise RuntimeError('Development app exited during startup')
                except (OSError, RuntimeError):
                    stop(child)
                    shutil.rmtree(candidate_folder)
                    child = subprocess.Popen([str(old_executable)], cwd=ROOT, env=app_environment,
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if old_executable else None
                    write_state(control, 'launch-failed', child, old_executable)
                    if args.once or child is None:
                        return 1
                    time.sleep(1)
                    if child.poll() is not None:
                        raise RuntimeError('Previous development app could not be restored')
                    print('Launch failed; previous app restored. Save again to retry.', flush=True)
                    continue
                folder, executable = candidate_folder, candidate
                if old_folder:
                    shutil.rmtree(old_folder)
                publish_ready(control, executable, current)
                write_state(control, 'running', child, executable)
                print('Development app restarted. Save an Apple source file to rebuild.', flush=True)
            if child and child.poll() is not None:
                break
            if args.once:
                child.wait()
                break
            time.sleep(1)
    except KeyboardInterrupt:
        print('Stopping development app.', flush=True)
    finally:
        stop(child)
        if final_status != 'ready':
            write_state(control, final_status)
        # Keep the last signed bundle for --launch-ready; old generations are removed above.
        lock.close()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
