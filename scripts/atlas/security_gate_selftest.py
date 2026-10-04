#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def write_executable(path, text): path.write_text(text); path.chmod(0o755)

def main():
    with tempfile.TemporaryDirectory(prefix='atlas-security-selftest-') as temporary:
        base = Path(temporary); template = base / 'template'
        (template / 'scripts/atlas').mkdir(parents=True)
        for name in ['security-regression.sh', 'security_regression.py', 'sync-mole-runtime.sh', 'mole-runtime-files.txt']:
            shutil.copy2(ROOT / 'scripts/atlas' / name, template / 'scripts/atlas' / name)
        shutil.copy2(ROOT / '.shellcheckrc', template / '.shellcheckrc')
        for name in (ROOT / 'scripts/atlas/mole-runtime-files.txt').read_text().splitlines():
            if not name or name.startswith('#'): continue
            for rel in [name, 'Packages/AtlasCoreAdapters/Sources/AtlasCoreAdapters/Resources/MoleRuntime/' + name]:
                dst = template / rel; dst.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(ROOT / rel, dst)
        cases = ['success', 'runtime_drift', 'failed_test', 'missing_bats', 'zero_swift', 'zero_swift_class', 'skipped_swift', 'skipped_shell', 'zero_go_package', 'prior_component_failure']
        for mode in cases:
            root = base / mode; shutil.copytree(template, root)
            commands = root / 'fake-bin'; commands.mkdir()
            for name, target in [('bash', '/bin/bash'), ('dirname', '/usr/bin/dirname'), ('python3', shutil.which('python3'))]: (commands / name).symlink_to(target)
            if mode != 'missing_bats':
                tap = '1..1\n' + ('not ok 1 injected\n' if mode in ['failed_test', 'prior_component_failure'] else 'ok 1 fixture\n')
                if mode == 'skipped_shell': tap = '1..1\nok 1 critical # skip unavailable\n'
                write_executable(commands / 'bats', '#!/bin/bash\nprintf %s ' + shlex.quote(tap) + '\n' + ('exit 1\n' if mode in ['failed_test', 'prior_component_failure'] else ''))
            write_executable(commands / 'shellcheck', '#!/bin/bash\nexit 0\n')
            import importlib.util
            specification = importlib.util.spec_from_file_location('gate', ROOT / 'scripts/atlas/security_regression.py')
            module = importlib.util.module_from_spec(specification); specification.loader.exec_module(module)
            names = module.SWIFT_FILTER.split('|')
            if mode == 'zero_swift_class': names = names[:-1]
            swift = '' if mode == 'zero_swift' else ''.join("Test Case '-[Fixture." + name + " testAssertion]' passed (0.001 seconds)\n" for name in names)
            if mode == 'skipped_swift': swift += "Test Case '-[Fixture.AtlasFileSafetyTests testSkipped]' skipped (0.001 seconds)\n"
            write_executable(commands / 'swift', '#!/bin/bash\nprintf %s ' + shlex.quote(swift) + '\n')
            events = []
            for package in ['github.com/tw93/mole/internal/safefile', 'github.com/tw93/mole/cmd/safe-remove']:
                if mode != 'zero_go_package' or package.endswith('safefile'): events.append(json.dumps({'Action':'pass','Test':'TestFixture','Package':package}))
            write_executable(commands / 'go', '#!/bin/bash\nprintf %s ' + shlex.quote('\n'.join(events) + '\n') + '\n')
            if mode == 'runtime_drift':
                with (root / 'lib/core/file_ops.sh').open('a') as stream: stream.write('\n# injected drift\n')
            result = subprocess.run([str(root / 'scripts/atlas/security-regression.sh'), '--component', 'all'], env={**os.environ, 'PATH':str(commands)}, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            passed = result.returncode == 0 and 'ATLAS_SECURITY_GATE=PASS component=all' in result.stdout
            if passed != (mode == 'success'):
                raise RuntimeError(mode + ': unexpected gate result\n' + result.stdout)
            print('ok ' + mode)
        print('ATLAS_SECURITY_SELFTEST=PASS cases=' + str(len(cases)))

if __name__ == '__main__': main()
