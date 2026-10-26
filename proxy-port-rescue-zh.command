#!/bin/zsh
# 代理端口急救（macOS，简体中文）
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 AnsonZhang0129
# 许可全文：https://polyformproject.org/licenses/noncommercial/1.0.0/
# 运行：双击此文件，或在终端执行 zsh /完整路径/本文件.command。
# 要求：已安装 Python 3；只使用标准库和 macOS 自带的 scutil、curl。
# 帮助：zsh /完整路径/本文件.command --help
# 默认目标：已有的 ~/.codex/.env；其他应用可用 --env 指定已有文件。
# 仅同步六项 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 及其小写变量；不改系统代理。
# 验证会通过所选本机 HTTP / 混合代理访问 https://example.com/。
# 不会发送配置内容，不会启动、停止或修改任何代理客户端。
# 写入前确认并备份，空回车取消；向导中输入 q 退出、第一步输入 r 恢复。
# 恢复会还原整个配置文件。请确认旧端口仍然可用。
# 此文件内置完整急救向导，可单独移动、保存和运行。
set -u
if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 --version >/dev/null 2>&1; then
  TASK_PYTHON_BIN=/usr/bin/python3
elif command -v python3 >/dev/null 2>&1; then
  TASK_PYTHON_BIN="$(command -v python3)"
else
  print '没有找到已安装的 Python 3，向导无法启动。没有修改任何配置。'
  print '请先安装 Python 3 再重试；本工具不会联网下载依赖。'
  read -r '?按回车结束。' || true
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
        raise Stop('无法运行本机检查工具，或检查超时：' + Path(args[0]).name) from e


def endpoint(host, port):
    if host not in ('127.0.0.1', 'localhost', '::1'):
        raise Stop('检测到非本机代理；本工具不自动改写。请在代理客户端中核对本机 HTTP / 混合端口。')
    try:
        p = int(port)
    except (TypeError, ValueError):
        raise Stop('代理端口不是有效数字。')
    if not 1 <= p <= 65535:
        raise Stop('代理端口必须在 1–65535 之间。')
    return ('127.0.0.1' if host == 'localhost' else host, p)


def url(ep):
    host, port = ep
    return 'http://{}:{}'.format('[' + host + ']' if ':' in host else host, port)


def system_target(raw=None):
    if raw is None:
        result = call(['/usr/sbin/scutil', '--proxy'])
        if result.returncode:
            raise Stop('读取 macOS 系统代理失败。')
        raw = result.stdout
    values = dict(re.findall(r'^\s*(\w+)\s*:\s*([^\n]+?)\s*$', raw, re.M))
    if values.get('ProxyAutoConfigEnable') == '1' or values.get('ProxyAutoDiscoveryEnable') == '1':
        raise Stop('系统正在使用自动代理 / PAC，无法据此猜端口。可在代理客户端设置确认 HTTP 或混合端口后，选择手动输入。')
    candidates = []
    for scheme in ('HTTP', 'HTTPS'):
        if values.get(scheme + 'Enable') == '1':
            candidates.append(endpoint(values.get(scheme + 'Proxy'), values.get(scheme + 'Port')))
    if not candidates:
        raise Stop('没有启用的本机 HTTP / HTTPS 系统代理。请先连接代理客户端并打开它的系统代理；或在代理客户端设置确认 HTTP / 混合端口后手动输入。')
    if len(set(candidates)) != 1:
        raise Stop('HTTP 和 HTTPS 系统代理不一致，停止自动选择。请先在代理客户端中重新启用系统代理，或核对端口后手动输入。')
    return candidates[0]


def safe_value(raw):
    value = raw.decode('utf-8', errors='replace').strip().strip('"\'')
    try:
        obj = urlsplit(value)
        if obj.scheme not in ('http', 'https', 'socks5', 'socks5h') or not obj.hostname or not obj.port:
            return '[非标准值，已隐藏]'
        host = obj.hostname
        # Display only known local hosts; never show credentials, queries or unknown names.
        if host not in ('127.0.0.1', 'localhost', '::1'):
            return '[非本机代理，地址已隐藏]'
        return '{}://{}:{}'.format(obj.scheme, '[' + host + ']' if ':' in host else host, obj.port)
    except ValueError:
        return '[无法识别的值，已隐藏]'


def read_regular(path):
    path = Path(path)
    try:
        # Reject symlinked parents as well as a symlinked .env.
        for item in (path,) + tuple(path.parents):
            if item.is_symlink():
                raise Stop('路径含符号链接，停止操作：' + str(path))
        before_open = path.lstat()
        if not stat.S_ISREG(before_open.st_mode):
            raise Stop('配置或备份不是普通文件。')
        fd = os.open(str(path), os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0))
        with os.fdopen(fd, 'rb') as f:
            info = os.fstat(f.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise Stop('配置或备份不是普通文件。')
            if info.st_uid != os.getuid():
                raise Stop('配置或备份不属于当前用户，停止操作。')
            if info.st_size > 1024 * 1024:
                raise Stop('配置文件异常大，停止操作。')
            return f.read(), info
    except FileNotFoundError:
        raise Stop('找不到文件：' + str(path) + '。请核对路径；本工具不会创建配置文件。')
    except OSError as e:
        raise Stop('读取文件失败：' + str(path)) from e


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
            raise Stop('发现复杂或跨行的代理设置，停止自动改写；请使用文本编辑器人工核对。')
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
    print('\n应用的独立代理配置：' + str(path))
    found = {}
    for line in data.splitlines(keepends=True):
        match = LINE.fullmatch(line)
        if match:
            key = match.group(2).decode()
            found.setdefault(key, []).append(safe_value(match.group(4)))
    for key in KEYS:
        values = found.get(key, ['[未设置]'])
        print('  {} = {}'.format(key, ' / '.join(values)))
    if expected:
        correct = all(found.get(key) == [url(expected)] for key in KEYS)
        print('\n结论：' + ('六项设置已与所选端口一致，无需重复修复。' if correct else '至少一项与所选端口不同、缺失或重复；请核对后再修复。'))
    return data, info


def probe(ep):
    host, port = ep
    try:
        with socket.create_connection((host, port), timeout=3):
            pass
    except OSError:
        return False, '本机端口没有接通。先确认代理客户端已运行，以及输入的是 HTTP / 混合代理端口。'
    # -q must be first: ignore ~/.curlrc. Explicit proxy + empty noproxy ignore ambient bypasses.
    # curl verifies both CONNECT and the remote TLS certificate; no -k, credentials or cookies.
    result = call(['/usr/bin/curl', '-q', '--silent', '--show-error', '--proxy', url(ep),
                   '--noproxy', '', '--connect-timeout', '5', '--max-time', '15',
                   '--output', '/dev/null', '--write-out', '%{http_connect} %{http_code}',
                   'https://example.com/'], timeout=18)
    fields = result.stdout.strip().split()
    if result.returncode == 0 and len(fields) == 2 and fields[0] == '200' and fields[1].isdigit() and 200 <= int(fields[1]) < 400:
        return True, '端口已接通，HTTP CONNECT 与 HTTPS 证书验证均通过。'
    return False, '端口在监听，但 HTTP CONNECT / HTTPS 验证未通过（curl 返回码 {}）。可能是 SOCKS 专用端口、节点 / 网络异常，或测试网站受限；暂不改配置。'.format(result.returncode)


def backup_folder(path):
    # Keep existing default backups compatible; isolate other filenames.
    return path.parent / (BACKUP_DIRNAME if path.name == '.env' else path.name + '.proxy-port-backups')


def secure_backup(path, data):
    folder = backup_folder(path)
    if folder.is_symlink():
        raise Stop('备份目录是符号链接，停止操作。')
    folder.mkdir(mode=0o700, exist_ok=True)
    if not folder.is_dir() or folder.stat().st_uid != os.getuid():
        raise Stop('备份目录无效或不属于当前用户。')
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
        raise Stop('配置在检查后发生变化，为避免覆盖他人修改，已停止。请重新检查。')
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
            raise Stop('配置刚被其他程序修改，已停止覆盖；备份仍保留。')
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)
    return backup


def confirm(text):
    print('\n' + text)
    return input('输入“确认”并按回车才会写入；直接回车取消：').strip() == '确认'


def choose_target(port):
    if port is not None:
        selected = endpoint('127.0.0.1', port)
        print('手动指定：' + url(selected) + '（须是代理客户端的 HTTP 或混合端口）')
        try:
            detected = system_target()
            print('系统代理当前为：' + url(detected))
            if detected != selected:
                print('注意：手动端口和系统代理不同。本工具只改应用文件；请先确认代理客户端的实际端口。')
        except Stop as e:
            print('系统代理提示：' + str(e))
        return selected
    selected = system_target()
    print('从 macOS 系统代理识别到：' + url(selected))
    return selected


def check(path, port=None):
    try:
        selected = choose_target(port)
    except Stop as e:
        show_env(path)
        print('\n无法自动选择：' + str(e))
        return 2
    show_env(path, selected)
    ok, message = probe(selected)
    print('\n连接检查：' + message)
    print('这里只验证所选代理与测试站点；不代表应用的账号、云端或全部功能一定正常。')
    print('本次没有修改任何配置。')
    return 0 if ok else 2


def repair(path, port=None):
    selected = choose_target(port)
    data, info = show_env(path, selected)
    new_data = transformed(data, selected)
    if new_data == data:
        print('\n配置内容已一致，没有写入，也没有创建重复备份。')
        return 0
    ok, message = probe(selected)
    print('\n连接检查：' + message)
    if not ok:
        raise Stop('没有修改配置。请先解决以上端口验证问题。')
    if not confirm('将把上述 6 项代理统一设为 {}。只修改 {}，保留其他设置，先备份。'.format(url(selected), path)):
        print('已取消，没有修改配置。')
        return 0
    if port is None and system_target() != selected:
        raise Stop('系统代理在确认期间发生变化，没有修改配置。请重新检查。')
    # Re-probe after confirmation so a slow response cannot write an obviously stale port.
    ok, message = probe(selected)
    if not ok:
        raise Stop('确认后端口验证失败，没有修改配置。')
    backup = atomic_replace(path, new_data, data, info)
    print('\n修复已完成。备份：' + str(backup))
    print('请保存正在进行的工作，使用 ⌘Q 完全退出使用此配置的应用，再重新打开。')
    print('随后重试原来失败的操作。本工具不会退出应用或中断你的任务。')
    return 0


def restore(path, backup_path):
    backup_path = Path(backup_path).expanduser().absolute()
    saved, _ = read_regular(backup_path)
    current, info = read_regular(path)
    if saved == current:
        print('备份与当前文件相同，无需恢复。')
        return 0
    print('将恢复整个 .env 文件（包括备份中的其他设置）。')
    print('来源：' + str(backup_path))
    print('目标：' + str(path))
    print('恢复旧端口前，请确认代理客户端也已经切回该端口。')
    if not confirm('当前文件也会先备份，便于撤销这次恢复。'):
        print('已取消，没有修改配置。')
        return 0
    recovery = atomic_replace(path, saved, current, info)
    print('已恢复。恢复前的文件保存在：' + str(recovery))
    print('保存任务后用 ⌘Q 完全退出并重新打开使用此配置的应用，再测试原故障。')
    return 0


def menu(path):
    while True:
        print('\n代理端口应急工具\n1. 只检查（不修改）\n2. 按系统当前端口修复\n3. 手动输入代理客户端的 HTTP / 混合端口并修复\n4. 从指定备份恢复\n0. 退出')
        choice = input('请选择：').strip()
        try:
            if choice == '0' or choice == '':
                return 0
            if choice == '1':
                check(path)
            elif choice == '2':
                repair(path)
            elif choice == '3':
                repair(path, input('输入代理客户端当前的 HTTP / 混合端口数字：').strip())
            elif choice == '4':
                raw = input('粘贴备份文件的完整路径（可将文件拖入终端后去掉外层引号）：').strip()
                if raw:
                    restore(path, raw.strip('"\''))
            else:
                print('请选择 0–4。')
        except Stop as e:
            print('\n已停止：' + str(e))


class Cancelled(Exception):
    pass


def ask(prompt):
    answer = input(prompt).strip()
    if answer.lower() == 'q':
        raise Cancelled()
    return answer


def step(number, title):
    print('\n' + '─' * 42)
    print('第 {} / 4 步 · {}'.format(number, title), flush=True)
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
        return '尚未设置'
    summary = '、'.join(unique)
    if len(found) < len(KEYS):
        summary += '（部分设置缺失）'
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
            print('系统当前使用的代理端口：{}'.format(selected[1]))
            return selected, False
        except Stop as e:
            print('\n暂时无法自动找到当前端口。')
            print(str(e))
            print('请在代理客户端的设置中查看 HTTP 或混合代理端口；不要使用 SOCKS 专用端口。')
            raw = ask('看到端口就输入数字；刚连接好代理客户端可直接回车重查；q 退出：')
            if raw:
                try:
                    return endpoint('127.0.0.1', raw), True
                except Stop:
                    print('请输入 1–65535 之间的端口数字，以代理客户端当前设置为准。')


def guided_finish():
    step(4, '重新打开应用并验证')
    print('① 保存正在进行的任务，保持代理客户端连接。')
    print('② 在使用此配置的应用中按 ⌘Q 完全退出，再重新打开。')
    print('③ 重试原来失败的操作，检查错误是否消失。')
    print('\n本工具不会替你退出应用。终端窗口可以一直保留。')
    while True:
        result = ask('试过后输入 1＝已恢复，2＝仍报错；直接回车＝稍后再试：')
        if result == '1':
            print('\n你已确认原来的操作恢复。下次端口再变，重新打开此文件即可。')
            return 0
        if result == '2':
            print('\n当前代理端口已经核对并通过通路检查，请先保留现在的配置。')
            print('保存完整报错和发生时间，后续继续查应用连接；不要反复更换端口。')
            print('测试网站能连通，不代表应用的账号或所有云端功能都已恢复。')
            return 2
        if result == '':
            print('\n端口检查已完成，应用是否恢复还需你稍后按上面三步验证。')
            return 0
        print('输入 1、2，或直接回车即可。')


def guided_restore(path):
    folder = backup_folder(path)
    if folder.is_symlink():
        raise Stop('备份目录异常，已停止恢复。')
    backups = []
    for candidate in sorted(folder.glob('.env-*.bak'), reverse=True):
        try:
            saved, info = read_regular(candidate)
            backups.append((candidate, saved, info))
        except Stop:
            continue
    if not backups:
        print('\n还没有本工具生成的备份，无需恢复。回车重新开始检查，q 退出。')
        ask('')
        return False
    print('\n可恢复的备份（最多列出最近 10 份）：')
    for index, (candidate, saved, info) in enumerate(backups[:10], 1):
        stamp = datetime.datetime.fromtimestamp(info.st_mtime).strftime('%Y-%m-%d %H:%M:%S')
        print('  {}. {} · 端口 {}'.format(index, stamp, compact_config(saved)))
    while True:
        raw = ask('输入要恢复的编号；直接回车返回检查；q 退出：')
        if not raw:
            return False
        if raw.isdigit() and 1 <= int(raw) <= min(10, len(backups)):
            candidate, saved, _ = backups[int(raw) - 1]
            break
        print('请填写列表中的编号。')
    current, info = read_regular(path)
    print('\n当前应用端口：' + compact_config(current))
    print('备份中的端口：' + compact_config(saved))
    print('恢复将还原当时整份应用配置，并先备份当前版本。')
    print('旧端口如果已经失效，恢复它也不能恢复连接。')
    answer = ask('确定恢复请输入 y；直接回车取消：')
    if answer.lower() not in ('y', 'yes', '确认'):
        print('已取消恢复。')
        return False
    if saved != current:
        backup = atomic_replace(path, saved, current, info)
        print('\n已恢复。当前版本也已备份：' + str(backup))
    else:
        print('\n备份与当前文件一致，无需写入。')
    print('保存任务后完整退出并重开使用此配置的应用，再测试原故障。')
    return True


def wizard(path):
    changed = False
    print('\n╭──────────────────────────────────────────╮')
    print('│              代理端口急救向导            │')
    print('╰──────────────────────────────────────────╯')
    print('跟着提示操作即可，不需要懂命令或配置文件。')
    print('任何一步输入 q 都可退出；需要修改时会先问你。')
    print('配置文件：' + str(path))
    print('仅适用于已使用此 .env 代理配置的应用；不会创建缺失的配置文件。')
    print('验证将经所选代理访问 https://example.com/；不会发送配置内容。')
    try:
        step(1, '准备好代理客户端')
        print('请打开代理客户端，确认已连接，并启用 HTTP 或混合代理端口。')
        start = ask('准备好后按回车开始；需要恢复备份时输入 r：')
        if start.lower() == 'r' and guided_restore(path):
            return 0
        while True:
            step(2, '自动检查当前端口')
            selected, manual = guided_target()
            data, info = read_regular(path)
            new_data = transformed(data, selected)
            same = matches_target(data, selected)
            print('应用记住的端口：' + compact_config(data))
            print('正在验证端口 {} 能否使用，请稍候（约 20 秒内）…'.format(selected[1]), flush=True)
            ok, message = probe(selected)
            if not ok:
                print('\n这个端口暂时未通过验证，没有修改配置。')
                print(message)
                print('请核对代理客户端的连接状态和 HTTP / 混合端口，并检查网络是否可用。')
                ask('处理好后按回车重新检查；q 退出：')
                continue
            print('✓ 端口验证通过。')
            step(3, '核对并修复')
            if same:
                print('✓ 当前端口一致，无需修改配置。')
            else:
                print('应用需要同步到当前端口：{}'.format(selected[1]))
                print('下一步会自动备份，再更新应用的代理端口。')
                answer = ask('要修复请输入 y 并回车；直接回车取消：')
                if answer.lower() not in ('y', 'yes', '确认'):
                    print('\n已取消，没有修改配置。下次直接重新打开此文件即可。')
                    return 0
                if not manual and system_target() != selected:
                    print('\n代理客户端端口刚刚又变了，本次没有写入。重新检查后会再次请你确认。')
                    continue
                ok, message = probe(selected)
                if not ok:
                    print('\n确认后端口验证失败，没有修改配置。')
                    print(message)
                    ask('处理好代理客户端后回车重查；q 退出：')
                    continue
                backup = atomic_replace(path, new_data, data, info)
                changed = True
                print('✓ 修复完成，应用现在使用端口 {}。'.format(selected[1]))
                print('原文件已自动备份。要撤销时重新打开向导，在第一步输入 r。')
            return guided_finish()
    except (Cancelled, EOFError, KeyboardInterrupt):
        if changed:
            print('\n已退出向导。刚才的修复已保存；仍可重新打开向导输入 r 恢复备份。')
        else:
            print('\n已退出，没有修改配置。')
        return 0


def main():
    argparse._ = lambda message: {
        'usage: ': '用法：',
        'options': '选项',
        'optional arguments': '可选参数',
        'show this help message and exit': '显示帮助并退出',
        'argument %s: %s': '参数 %s：%s',
        'invalid %(type)s value: %(value)r': '%(type)s 类型的值无效：%(value)r',
        'not allowed with argument %s': '不能与参数 %s 同时使用',
        'unrecognized arguments: %s': '无法识别的参数：%s',
        'expected one argument': '需要提供一个值',
        '%(prog)s: error: %(message)s\n': '%(prog)s：错误：%(message)s\n',
    }.get(message, message)
    parser = argparse.ArgumentParser(prog='proxy-port-rescue-zh.command', description='代理端口急救向导；默认逐步引导。默认检查 ~/.codex/.env；必须已有此文件。')
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--check', action='store_true', help='只读检查')
    group.add_argument('--repair', action='store_true', help='核对、验证并经确认后修复')
    group.add_argument('--restore', metavar='BACKUP_PATH', help='经确认后恢复明确指定的备份')
    group.add_argument('--advanced', action='store_true', help='打开原来的高级菜单')
    parser.add_argument('--port', type=int, help='手动指定本机 HTTP / 混合端口；不修改系统代理')
    parser.add_argument('--env', type=Path, default=DEFAULT_ENV, metavar='PATH', help='已有的应用 .env 文件路径；默认 ~/.codex/.env')
    args = parser.parse_args()
    path = args.env.expanduser().absolute()
    if args.port is not None and not (args.check or args.repair):
        parser.error('--port 需要与 --check 或 --repair 一起使用')
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
        print('\n已取消。')
        return 130
    except Stop as e:
        print('\n已停止：' + str(e))
        return 2
    except OSError:
        print('\n文件操作失败，已停止。请检查目录权限与磁盘空间，再使用备份。')
        return 2


if __name__ == '__main__':
    sys.exit(main())

CODEX_PROXY_WIZARD_PYTHON
)
TASK_EXIT_CODE=0
"$TASK_PYTHON_BIN" -B -c "$TASK_WIZARD_CODE" "$@" || TASK_EXIT_CODE=$?
if [[ $# -eq 0 && -t 0 ]]; then
  print '
向导已结束。按回车结束运行，然后可关闭终端窗口。'
  read -r || true
fi
exit "$TASK_EXIT_CODE"
