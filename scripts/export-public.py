#!/usr/bin/env python3
"""Export reviewed source into a new directory without Git history or runtime data."""
import argparse
import ipaddress
import pathlib
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET


ROOT_FILES = {'.gitattributes', '.gitignore', 'README.md', 'LICENSE',
              'THIRD_PARTY_NOTICES.md', 'package.json', 'package-lock.json'}
CODE_EXTENSIONS = {'.mjs', '.js', '.py', '.ps1', '.sh'}
UI_FILES = {'AwardStateTests.swift', 'Info.plist'}
BLOCKED_PARTS = {'.git', 'node_modules', '__pycache__', 'work', 'outputs', 'dist'}


def allowed(path):
    parts = path.parts
    if any(part in BLOCKED_PARTS for part in parts):
        return False
    if len(parts) == 1:
        return path.name in ROOT_FILES
    group = parts[0]
    if group == 'CodexPocket':
        return parts[1] != 'Core' and path.suffix in {'.swift', '.plist', '.json', '.png', '.pdf', '.js', '.txt'}
    if group == 'CodexPocketTests':
        return path.suffix in {'.swift', '.plist'}
    if group == 'CodexPocketUITests':
        return len(parts) == 2 and path.name in UI_FILES
    if group == 'CodexPocket.xcodeproj':
        return path.name == 'project.pbxproj' or parts[1:3] == ('xcshareddata', 'xcschemes') and path.suffix == '.xcscheme'
    if group in {'bridge', 'connector', 'scripts'}:
        return (path.suffix in CODE_EXTENSIONS or group == 'scripts' and
                (path.name == 'sea-config.json' or parts[1] == 'fixtures' and
                 path.suffix in {'.json', '.png', '.jpg', '.jpeg', '.pdf'}) or
                path.as_posix() in {'bridge/ui.html', 'connector/web/index.html', 'connector/web/style.css'})
    if group == 'packaging':
        return path.suffix in CODE_EXTENSIONS | {'.json', '.plist', '.ico', '.png', '.md', '.cmd', '.command', '.txt'}
    if group == 'docs':
        return parts[1] == 'public' and path.suffix == '.md'
    if group == 'licenses':
        return True
    return group == '.github' and parts[1] == 'workflows' and path.suffix in {'.yml', '.yaml'}


PATTERNS = {
    'personal-account': r'com\.(?!example\.|codexpocket\.)[a-z][a-z0-9]+\.codexpocket',
    'personal-path': r'/Users/(?!<|(?:test|tester|user|me|u|xxx|example|fixture)(?:/|\b))[a-z0-9._-]+|[A-Z]:\\+Users\\+(?!<|(?:Test|User|Example)(?:\\|\b))[a-z0-9._-]+',
    'personal-hostname': r'\b[a-z0-9.-]+\.kdns\.fr\b',
    'session-id': r'\b01[a-f0-9]{6}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}\b',
    'certificate-pin': r'pinnedCert\w*\s*=\s*["\x27][a-fA-F0-9]{64}',
    'credential': r'Bearer\s+[A-Za-z0-9_+=/-]{20,}|[?&](?:t|token|api_key)=[A-Za-z0-9_-]{16,}|(?:sk-|tvly-)[A-Za-z0-9_-]{16,}|BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY',
}
PATTERNS['credential'] += r'|(?:token|secret|api[_-]?key|password)["\x27]?\s*[:=]\s*["\x27][a-z0-9_+/=-]{24,}'
DOCUMENTATION_NETS = [ipaddress.ip_network(value) for value in
                      ['192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24']]
IPV4 = re.compile(r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')


def private_address(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return False
    return not (address.is_loopback or address.is_unspecified
                or any(address in network for network in DOCUMENTATION_NETS))


def inspect_text(text, name):
    violations = []
    for number, line in enumerate(text.splitlines(), 1):
        for category, pattern in PATTERNS.items():
            if re.search(pattern, line, re.IGNORECASE):
                violations.append(f'{category}: {name}:{number}')
        if any(private_address(match.group()) for match in IPV4.finditer(line)):
            violations.append(f'network-address: {name}:{number}')
    return violations


def normalize_reviewed_examples(text, name):
    if name == 'CodexPocketTests/BridgeURLTests.swift':
        text = IPV4.sub(lambda match: '203.0.113.10' if private_address(match.group())
                        else match.group(), text)
        text = re.sub(r'\b[a-z0-9-]+\.kdns\.fr\b', 'relay.example', text)
    return text


def trim_mock_project(text):
    group = re.search(r'/\* CodexPocketUITests \*/\s*=\s*\{isa = PBXGroup; children = \((.*?)\);', text, re.S)
    if not group:
        if 'CodexPocketUITests' in text:
            raise ValueError('unsupported-project-layout: CodexPocket.xcodeproj/project.pbxproj')
        return text
    removed = {identifier for identifier, name in
               re.findall(r'([A-F0-9]{24}) /\* ([^*]+) \*/', group[1])
               if name not in UI_FILES}
    for identifier, file_ref in re.findall(
            r'([A-F0-9]{24}) /\*[^*]*\*/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24})', text):
        if file_ref in removed:
            removed.add(identifier)
    for identifier in removed:
        text = re.sub(r'(?m)^[\t ]*' + identifier + r'(?: /\*[^*]*\*/)? = \{[^\n]*\};\n?', '', text)
        text = re.sub(identifier + r'(?: /\*[^*]*\*/)?(?:,\s*)?', '', text)
    return text


def disable_live_scheme(text):
    root = ET.fromstring(text)
    for reference in root.iter('TestableReference'):
        buildable = reference.find('BuildableReference')
        if buildable is not None and buildable.get('BlueprintName') == 'CodexPocketUITests':
            reference.set('skipped', 'YES')
    return ET.tostring(root, encoding='unicode') + '\n'


def export_public(source, destination):
    source = source.resolve()
    if not source.is_dir():
        raise ValueError('missing-source')
    if destination.exists() or destination.is_symlink():
        raise ValueError('destination-exists')
    selected, violations = [], []
    for path in sorted(source.rglob('*')):
        name = path.relative_to(source)
        if not allowed(name):
            continue
        if path.is_symlink():
            violations.append(f'symlink: {name.as_posix()}')
            continue
        if not path.is_file():
            continue
        data = path.read_bytes()
        text = data.decode('utf-8', errors='replace')
        original_text = text
        public_name = name.as_posix()
        if path.suffix not in {'.png', '.jpg', '.jpeg', '.pdf', '.ico'}:
            text = normalize_reviewed_examples(text, public_name)
            if public_name == 'CodexPocket.xcodeproj/project.pbxproj':
                text = trim_mock_project(text)
            elif path.suffix == '.xcscheme':
                try:
                    text = disable_live_scheme(text)
                except ET.ParseError:
                    raise ValueError(f'unsupported-scheme: {public_name}') from None
            if text != original_text:
                data = text.encode('utf-8')
        violations.extend(inspect_text(text, public_name))
        selected.append((name, data, path.stat().st_mode & 0o777))
    if violations:
        raise ValueError('\n'.join(violations))
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = pathlib.Path(tempfile.mkdtemp(prefix='.public-export-', dir=destination.parent))
    try:
        for name, data, mode in selected:
            output = staging / name
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(data)
            output.chmod(mode)
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return len(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=pathlib.Path)
    parser.add_argument('--source', type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    try:
        count = export_public(args.source, args.destination)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    except OSError:
        print('filesystem-error: export not completed', file=sys.stderr)
        return 1
    print(f'Exported {count} files without repository history.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
