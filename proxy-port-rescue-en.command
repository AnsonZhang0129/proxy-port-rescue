#!/bin/zsh
# Proxy Port Rescue (macOS, English)
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 AnsonZhang0129
# Full license: https://polyformproject.org/licenses/noncommercial/1.0.0/
# Run: double-click this file, or run zsh /full/path/to/this-file.command in Terminal.
# Requires an installed Python 3; uses only its standard library and macOS scutil/curl.
# Help: zsh /full/path/to/this-file.command --help
# Default target: an existing ~/.codex/.env; use --env for another existing file.
# Updates only HTTP_PROXY / HTTPS_PROXY / ALL_PROXY and lowercase variants, not system proxy settings.
# Verification connects to https://example.com/ through the selected local HTTP / mixed proxy.
# Configuration contents are never sent; no proxy client is started, stopped, or modified.
# Writes require confirmation and a backup; Return cancels. In the wizard, q quits and r at step 1 restores.
# Restore replaces the entire configuration file. Check that the old port is still usable.
# This file contains the entire recovery wizard; it can be moved and run on its own.
set -u
if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 --version >/dev/null 2>&1; then
  TASK_PYTHON_BIN=/usr/bin/python3
elif command -v python3 >/dev/null 2>&1; then
  TASK_PYTHON_BIN="$(command -v python3)"
else
  print 'Python 3 is not installed or could not run. The wizard cannot start. No configuration was changed.'
  print 'Install Python 3 and try again. This tool will not download dependencies.'
  read -r '?Press Return to exit.' || true
  exit 1
fi
TASK_WIZARD_CODE=$(cat <<'CODEX_PROXY_WIZARD_PYTHON'
#!/usr/bin/env python3
"""Local proxy-port recovery helper. No dependencies; never executes .env contents."""
import argparse
import datetime
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit

KEYS = ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
        'http_proxy', 'https_proxy', 'all_proxy')
KEY_PATTERN = '|'.join(KEYS)
ASSIGN = re.compile(rb'^[ \t]*(?:export[ \t]+)?(' + KEY_PATTERN.encode() + rb')[ \t]*=')
LINE = re.compile(rb'^([ \t]*(?:export[ \t]+)?)(' + KEY_PATTERN.encode() +
                  rb')([ \t]*=[ \t]*)("[^"\r\n]*"|\'[^\'\r\n]*\'|[^\s#"\']*)([ \t]*(?:#[^\r\n]*)?)(\r?\n)?$')
DEFAULT_ENV = Path.home() / '.codex' / '.env'
BACKUP_DIRNAME = 'proxy-port-backups'


class Stop(Exception):
    pass


def call(args, timeout=10):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Stop('A local check could not run or timed out: ' + Path(args[0]).name) from e


def endpoint(host, port):
    if host not in ('127.0.0.1', 'localhost', '::1'):
        raise Stop('A non-local proxy was detected. No automatic changes will be made. Check the local HTTP or mixed port in your proxy client.')
    try:
        p = int(port)
    except (TypeError, ValueError):
        raise Stop('The proxy port is not a valid number.')
    if not 1 <= p <= 65535:
        raise Stop('The proxy port must be between 1 and 65535.')
    return ('127.0.0.1' if host == 'localhost' else host, p)


def url(ep):
    host, port = ep
    return 'http://{}:{}'.format('[' + host + ']' if ':' in host else host, port)


def system_target(raw=None):
    if raw is None:
        result = call(['/usr/sbin/scutil', '--proxy'])
        if result.returncode:
            raise Stop('Failed to read the macOS system proxy.')
        raw = result.stdout
    values = dict(re.findall(r'^\s*(\w+)\s*:\s*([^\n]+?)\s*$', raw, re.M))
    if values.get('ProxyAutoConfigEnable') == '1' or values.get('ProxyAutoDiscoveryEnable') == '1':
        raise Stop('Automatic proxy configuration / PAC is enabled, so the port cannot be inferred. Check the HTTP or mixed port in your proxy client and enter it manually.')
    candidates = []
    for scheme in ('HTTP', 'HTTPS'):
        if values.get(scheme + 'Enable') == '1':
            candidates.append(endpoint(values.get(scheme + 'Proxy'), values.get(scheme + 'Port')))
    if not candidates:
        raise Stop('No local HTTP / HTTPS system proxy is enabled. Connect your proxy client and enable its system proxy, or check its HTTP / mixed port and enter it manually.')
    if len(set(candidates)) != 1:
        raise Stop('HTTP and HTTPS system proxies differ. Automatic selection stopped. Re-enable the system proxy in your client, or verify the port and enter it manually.')
    return candidates[0]


def safe_value(raw):
    value = raw.decode('utf-8', errors='replace').strip().strip('"\'')
    try:
        obj = urlsplit(value)
        if obj.scheme not in ('http', 'https', 'socks5', 'socks5h') or not obj.hostname or not obj.port:
            return '[Nonstandard value hidden]'
        host = obj.hostname
        # Display only known local hosts; never show credentials, queries or unknown names.
        if host not in ('127.0.0.1', 'localhost', '::1'):
            return '[Non-local proxy address hidden]'
        return '{}://{}:{}'.format(obj.scheme, '[' + host + ']' if ':' in host else host, obj.port)
    except ValueError:
        return '[Unrecognized value hidden]'


def read_regular(path):
    path = Path(path)
    try:
        # Reject symlinked parents as well as a symlinked .env.
        for item in (path,) + tuple(path.parents):
            if item.is_symlink():
                raise Stop('The path contains a symbolic link. Stopped: ' + str(path))
        before_open = path.lstat()
        if not stat.S_ISREG(before_open.st_mode):
            raise Stop('The configuration or backup is not a regular file.')
        fd = os.open(str(path), os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'rb') as f:
            info = os.fstat(f.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise Stop('The configuration or backup is not a regular file.')
            if info.st_uid != os.getuid():
                raise Stop('The configuration or backup is not owned by the current user. Stopped.')
            if info.st_size > 1024 * 1024:
                raise Stop('The configuration file is unexpectedly large. Stopped.')
            return f.read(), info
    except FileNotFoundError:
        raise Stop('File not found: ' + str(path) + '. Check the path; this tool will not create a configuration file.')
    except OSError as e:
        raise Stop('Failed to read file: ' + str(path)) from e


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def transformed(data, ep):
    target = url(ep).encode('ascii')
    lines = data.splitlines(keepends=True)
    ending = b'\r\n' if b'\r\n' in data else b'\n'
    seen = set()
    result = []
    for line in lines:
        match = LINE.fullmatch(line)
        if ASSIGN.match(line) and not match:
            raise Stop('Complex or multiline proxy settings were found. Automatic editing stopped; inspect the file in a text editor.')
        if match:
            prefix, key, eq, old, suffix, newline = match.groups()
            seen.add(key.decode())
            result.append(prefix + key + eq + target + suffix + (newline or b''))
        else:
            result.append(line)
    missing = [key for key in KEYS if key not in seen]
    if missing and result and not result[-1].endswith(b'\n'):
        result[-1] += ending
    result.extend(key.encode() + b'=' + target + ending for key in missing)
    return b''.join(result)


def show_env(path, expected=None):
    data, info = read_regular(path)
    print('\nApplication proxy configuration: ' + str(path))
    found = {}
    for line in data.splitlines(keepends=True):
        match = LINE.fullmatch(line)
        if match:
            key = match.group(2).decode()
            found.setdefault(key, []).append(safe_value(match.group(4)))
    for key in KEYS:
        values = found.get(key, ['[Not set]'])
        print('  {} = {}'.format(key, ' / '.join(values)))
    if expected:
        correct = all(found.get(key) == [url(expected)] for key in KEYS)
        print('\nResult: ' + ('All six settings match the selected port; no repeated repair is needed.' if correct else 'At least one setting differs, is missing, or is duplicated. Review before repairing.'))
    return data, info


def probe(ep):
    host, port = ep
    try:
        with socket.create_connection((host, port), timeout=3):
            pass
    except OSError:
        return False, 'The local port is not reachable. Verify that your proxy client is running and that this is its HTTP / mixed proxy port.'
    # -q must be first: ignore ~/.curlrc. Explicit proxy + empty noproxy ignore ambient bypasses.
    # curl verifies both CONNECT and the remote TLS certificate; no -k, credentials or cookies.
    result = call(['/usr/bin/curl', '-q', '--silent', '--show-error', '--proxy', url(ep),
                   '--noproxy', '', '--connect-timeout', '5', '--max-time', '15',
                   '--output', '/dev/null', '--write-out', '%{http_connect} %{http_code}',
                   'https://example.com/'], timeout=18)
    fields = result.stdout.strip().split()
    if result.returncode == 0 and len(fields) == 2 and fields[0] == '200' and fields[1].isdigit() and 200 <= int(fields[1]) < 400:
        return True, 'The port is reachable. HTTP CONNECT and HTTPS certificate verification passed.'
    return False, 'The port is listening, but HTTP CONNECT / HTTPS verification failed (curl exit code {}). This may be a SOCKS-only port, a proxy / network problem, or a blocked test website. No configuration will be changed.'.format(result.returncode)


def backup_folder(path):
    # Keep existing default backups compatible; isolate other filenames.
    return path.parent / (BACKUP_DIRNAME if path.name == '.env' else path.name + '.proxy-port-backups')


def secure_backup(path, data):
    folder = backup_folder(path)
    if folder.is_symlink():
        raise Stop('The backup directory is a symbolic link. Stopped.')
    folder.mkdir(mode=0o700, exist_ok=True)
    if not folder.is_dir() or folder.stat().st_uid != os.getuid():
        raise Stop('The backup directory is invalid or is not owned by the current user.')
    os.chmod(str(folder), 0o700)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup = folder / ('.env-' + stamp + '.bak')
    fd = os.open(str(backup), os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(fd, 'wb') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    return backup


def atomic_replace(path, new_data, old_data, old_info):
    current, info = read_regular(path)
    if current != old_data or identity(info) != identity(old_info):
        raise Stop('The configuration changed after inspection. Stopped to avoid overwriting those changes. Check again.')
    backup = secure_backup(path, old_data)
    fd, name = tempfile.mkstemp(prefix='.proxy-port-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as f:
            os.fchmod(f.fileno(), 0o600)
            f.write(new_data)
            f.flush()
            os.fsync(f.fileno())
        # Recheck immediately before replacing; this is an interactive local utility.
        current, info = read_regular(path)
        if current != old_data or identity(info) != identity(old_info):
            raise Stop('Another program just changed the configuration. Overwrite stopped; the backup is retained.')
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)
    return backup


def confirm(text):
    print('\n' + text)
    return input('Type confirm and press Return to write changes, or press Return to cancel: ').strip() == 'confirm'


def choose_target(port):
    if port is not None:
        selected = endpoint('127.0.0.1', port)
        print('Manually selected: ' + url(selected) + ' (must be the proxy client HTTP or mixed port)')
        try:
            detected = system_target()
            print('Current system proxy: ' + url(detected))
            if detected != selected:
                print('Note: the manual port differs from the system proxy. This tool only changes the application file; verify the proxy client port first.')
        except Stop as e:
            print('System proxy note: ' + str(e))
        return selected
    selected = system_target()
    print('Detected from the macOS system proxy: ' + url(selected))
    return selected


def check(path, port=None):
    try:
        selected = choose_target(port)
    except Stop as e:
        show_env(path)
        print('\nAutomatic selection failed: ' + str(e))
        return 2
    show_env(path, selected)
    ok, message = probe(selected)
    print('\nConnection check: ' + message)
    print('This only checks the selected proxy and test website, not account access or every application feature.')
    print('No configuration was changed.')
    return 0 if ok else 2


def repair(path, port=None):
    selected = choose_target(port)
    data, info = show_env(path, selected)
    new_data = transformed(data, selected)
    if new_data == data:
        print('\nThe configuration already matches. No file was written and no duplicate backup was created.')
        return 0
    ok, message = probe(selected)
    print('\nConnection check: ' + message)
    if not ok:
        raise Stop('No configuration was changed. Resolve the port verification problem first.')
    if not confirm('Set all six proxy variables to {}. Only {} will change; other settings will be preserved and a backup made first.'.format(url(selected), path)):
        print('Cancelled. No configuration was changed.')
        return 0
    if port is None and system_target() != selected:
        raise Stop('The system proxy changed while waiting for confirmation. No configuration was changed. Check again.')
    # Re-probe after confirmation so a slow response cannot write an obviously stale port.
    ok, message = probe(selected)
    if not ok:
        raise Stop('Port verification failed after confirmation. No configuration was changed.')
    backup = atomic_replace(path, new_data, data, info)
    print('\nRepair complete. Backup: ' + str(backup))
    print('Save your work, quit the application that uses this configuration with Command-Q, then reopen it.')
    print('Retry the operation that failed. This tool will not quit applications or interrupt your work.')
    return 0


def restore(path, backup_path):
    backup_path = Path(backup_path).expanduser().absolute()
    saved, _ = read_regular(backup_path)
    current, info = read_regular(path)
    if saved == current:
        print('The backup matches the current file. No restore is needed.')
        return 0
    print('Restoring replaces the entire .env file, including other settings in the backup.')
    print('Source: ' + str(backup_path))
    print('Destination: ' + str(path))
    print('Before restoring an old port, verify that your proxy client is using that port again.')
    if not confirm('The current file will be backed up first so you can undo this restore.'):
        print('Cancelled. No configuration was changed.')
        return 0
    recovery = atomic_replace(path, saved, current, info)
    print('Restored. The previous file was backed up to: ' + str(recovery))
    print('Save your work, quit and reopen the application using this configuration, then retry the failed operation.')
    return 0


def menu(path):
    while True:
        print('\nProxy Port Rescue\n1. Check only (no changes)\n2. Repair using the current system proxy port\n3. Enter the proxy client HTTP / mixed port and repair\n4. Restore a specified backup\n0. Quit')
        choice = input('Choose an option: ').strip()
        try:
            if choice == '0' or choice == '':
                return 0
            if choice == '1':
                check(path)
            elif choice == '2':
                repair(path)
            elif choice == '3':
                repair(path, input('Enter the proxy client current HTTP / mixed port number: ').strip())
            elif choice == '4':
                raw = input('Paste the full backup path (you can drag the file into Terminal, then remove enclosing quotes): ').strip()
                if raw:
                    restore(path, raw.strip('"\''))
            else:
                print('Choose 0-4.')
        except Stop as e:
            print('\nStopped: ' + str(e))


class Cancelled(Exception):
    pass


def ask(prompt):
    answer = input(prompt).strip()
    if answer.lower() == 'q':
        raise Cancelled()
    return answer


def step(number, title):
    print('\n' + '─' * 42)
    print('Step {} / 4 - {}'.format(number, title), flush=True)
    print('─' * 42)


def compact_config(data):
    values = []
    found = set()
    for line in data.splitlines(keepends=True):
        match = LINE.fullmatch(line)
        if match:
            found.add(match.group(2).decode())
            safe = safe_value(match.group(4))
            if safe.startswith('http://127.0.0.1:') or safe.startswith('http://localhost:'):
                values.append(safe.rsplit(':', 1)[1])
            else:
                values.append(safe)
    unique = list(dict.fromkeys(values))
    if not unique:
        return 'Not set'
    summary = ', '.join(unique)
    if len(found) < len(KEYS):
        summary += ' (some settings are missing)'
    return summary


def matches_target(data, selected):
    expected = url(selected).encode()
    found = set()
    for line in data.splitlines(keepends=True):
        match = LINE.fullmatch(line)
        if ASSIGN.match(line) and not match:
            return False
        if match:
            found.add(match.group(2).decode())
            if match.group(4).strip(b'\"\'') != expected:
                return False
    return found == set(KEYS)


def guided_target():
    while True:
        try:
            selected = system_target()
            print('Current system proxy port: {}'.format(selected[1]))
            return selected, False
        except Stop as e:
            print('\nThe current port could not be detected automatically.')
            print(str(e))
            print('Find the HTTP or mixed proxy port in your proxy client settings; do not use a SOCKS-only port.')
            raw = ask('Enter the port number, Return to retry after connecting your proxy client, or q to quit: ')
            if raw:
                try:
                    return endpoint('127.0.0.1', raw), True
                except Stop:
                    print('Enter a port number between 1 and 65535 from your proxy client current settings.')


def guided_finish():
    step(4, 'Reopen the application and verify')
    print('1. Save your work and keep the proxy client connected.')
    print('2. Quit the application using this configuration with Command-Q, then reopen it.')
    print('3. Retry the operation that failed and check whether the error is gone.')
    print('\nThis tool will not quit the application for you. You can leave this Terminal window open.')
    while True:
        result = ask('After testing, enter 1 = working, 2 = still failing, or press Return = test later: ')
        if result == '1':
            print('\nYou confirmed that the original operation works again. Reopen this file if the proxy port changes again.')
            return 0
        if result == '2':
            print('\nThe current proxy port passed verification. Keep the current configuration for now.')
            print('Save the full error and its time for further diagnosis, instead of repeatedly changing ports.')
            print('A reachable test website does not confirm that account access or all cloud features have recovered.')
            return 2
        if result == '':
            print('\nPort checking is complete. Follow the three steps above later to verify application recovery.')
            return 0
        print('Enter 1 or 2, or press Return.')


def guided_restore(path):
    folder = backup_folder(path)
    if folder.is_symlink():
        raise Stop('The backup directory is unsafe. Restore stopped.')
    backups = []
    for candidate in sorted(folder.glob('.env-*.bak'), reverse=True):
        try:
            saved, info = read_regular(candidate)
            backups.append((candidate, saved, info))
        except Stop:
            continue
    if not backups:
        print('\nNo backups from this tool are available. Press Return to check again, or q to quit.')
        ask('')
        return False
    print('\nAvailable backups (up to the 10 most recent):')
    for index, (candidate, saved, info) in enumerate(backups[:10], 1):
        stamp = datetime.datetime.fromtimestamp(info.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
        print('  {}. {} - port {}'.format(index, stamp, compact_config(saved)))
    while True:
        raw = ask('Enter a backup number to restore, Return to go back, or q to quit: ')
        if not raw:
            return False
        if raw.isdigit() and 1 <= int(raw) <= min(10, len(backups)):
            candidate, saved, _ = backups[int(raw) - 1]
            break
        print('Enter a number from the list.')
    current, info = read_regular(path)
    print('\nCurrent application port: ' + compact_config(current))
    print('Port in the backup: ' + compact_config(saved))
    print('Restoring replaces the whole configuration with the saved version, after backing up the current file.')
    print('Restoring an old port will not help if that port is no longer working.')
    answer = ask('Type y to restore, or press Return to cancel: ')
    if answer.lower() not in ('y', 'yes', 'confirm'):
        print('Restore cancelled.')
        return False
    if saved != current:
        backup = atomic_replace(path, saved, current, info)
        print('\nRestored. The previous version was also backed up: ' + str(backup))
    else:
        print('\nThe backup matches the current file. No write is needed.')
    print('Save your work, fully quit and reopen the application using this configuration, then retry the failed operation.')
    return True


def wizard(path):
    changed = False
    print('\n╭──────────────────────────────────────────╮')
    print('│            Proxy Port Rescue             │')
    print('╰──────────────────────────────────────────╯')
    print('Follow the prompts; no command-line or configuration experience is required.')
    print('Enter q at any prompt to quit. Changes require your confirmation.')
    print('Configuration file: ' + str(path))
    print('For applications already using this .env proxy configuration. Missing files will not be created.')
    print('Verification connects to https://example.com/ through the selected proxy; configuration contents are never sent.')
    try:
        step(1, 'Prepare your proxy client')
        print('Open your proxy client, connect it, and enable an HTTP or mixed proxy port.')
        start = ask('Press Return when ready, or enter r to restore a backup: ')
        if start.lower() == 'r' and guided_restore(path):
            return 0
        while True:
            step(2, 'Detect and verify the current port')
            selected, manual = guided_target()
            data, info = read_regular(path)
            new_data = transformed(data, selected)
            same = matches_target(data, selected)
            print('Port saved by the application: ' + compact_config(data))
            print('Verifying port {}. Please wait (usually within 20 seconds)...'.format(selected[1]), flush=True)
            ok, message = probe(selected)
            if not ok:
                print('\nThis port failed verification. No configuration was changed.')
                print(message)
                print('Check your proxy client connection, its HTTP / mixed port, and network availability.')
                ask('Press Return to retry after resolving the problem, or q to quit: ')
                continue
            print('✓ Port verification passed.')
            step(3, 'Review and repair')
            if same:
                print('✓ The current port matches; no configuration change is needed.')
            else:
                print('The application needs to use the current port: {}'.format(selected[1]))
                print('The next step will back up the file, then update the application proxy port.')
                answer = ask('Type y and press Return to repair, or press Return to cancel: ')
                if answer.lower() not in ('y', 'yes', 'confirm'):
                    print('\nCancelled. No configuration was changed. Reopen this file to try again later.')
                    return 0
                if not manual and system_target() != selected:
                    print('\nThe proxy port changed again. Nothing was written. It will be checked again before requesting fresh confirmation.')
                    continue
                ok, message = probe(selected)
                if not ok:
                    print('\nPort verification failed after confirmation. No configuration was changed.')
                    print(message)
                    ask('Resolve the proxy client problem, then press Return to retry, or q to quit: ')
                    continue
                backup = atomic_replace(path, new_data, data, info)
                changed = True
                print('✓ Repair complete. The application configuration now uses port {}.'.format(selected[1]))
                print('The original file was backed up. To undo, reopen the wizard and enter r at the first step.')
            return guided_finish()
    except (Cancelled, EOFError, KeyboardInterrupt):
        if changed:
            print('\nExited the wizard. The repair was saved; reopen the wizard and enter r to restore a backup.')
        else:
            print('\nExited. No configuration was changed.')
        return 0


def main():
    parser = argparse.ArgumentParser(prog='proxy-port-rescue-en.command', description='Proxy Port Rescue; starts a guided wizard by default. Uses ~/.codex/.env by default; the file must already exist.')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--check', action='store_true', help='Check without changing configuration')
    group.add_argument('--repair', action='store_true', help='Verify the proxy and repair after confirmation')
    group.add_argument('--restore', metavar='BACKUP_PATH', help='Restore the specified backup after confirmation')
    group.add_argument('--advanced', action='store_true', help='Open the advanced menu')
    parser.add_argument('--port', type=int, help='Specify a local HTTP / mixed port; does not change the system proxy')
    parser.add_argument('--env', type=Path, default=DEFAULT_ENV, metavar='PATH', help='Path to an existing application .env file; default: ~/.codex/.env')
    args = parser.parse_args()
    path = args.env.expanduser().absolute()
    if args.port is not None and not (args.check or args.repair):
        parser.error('--port requires --check or --repair')
    try:
        if args.check:
            return check(path, args.port)
        if args.repair:
            return repair(path, args.port)
        if args.restore:
            return restore(path, args.restore)
        if args.advanced:
            return menu(path)
        return wizard(path)
    except (EOFError, KeyboardInterrupt):
        print('\nCancelled.')
        return 130
    except Stop as e:
        print('\nStopped: ' + str(e))
        return 2
    except OSError:
        print('\nA file operation failed. Stopped. Check directory permissions and available disk space before using a backup.')
        return 2


if __name__ == '__main__':
    sys.exit(main())

CODEX_PROXY_WIZARD_PYTHON
)
TASK_EXIT_CODE=0
"$TASK_PYTHON_BIN" -B -c "$TASK_WIZARD_CODE" "$@" || TASK_EXIT_CODE=$?
if [[ $# -eq 0 && -t 0 ]]; then
  print '
The wizard has finished. Press Return to exit, then close the Terminal window.'
  read -r || true
fi
exit "$TASK_EXIT_CODE"
