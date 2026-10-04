#!/usr/bin/env python3
"""Count actual security assertions; a successful command with zero cases fails."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

class NotRunError(RuntimeError): pass

ROOT = Path(__file__).resolve().parents[2]
SHELL_CASES = ['tests/security_cli.bats', 'tests/mole_runtime_sync.bats', 'tests/pam_transaction.bats', 'tests/launch_item_safety.bats', 'tests/safe_remove_backend.bats']
SWIFT_FILTER = '|'.join(['AtlasFileSafetyTests', 'AtlasActionPlanRegistryTests', 'AtlasMutationAuthorizationTests', 'AtlasPartialMutationTests', 'AtlasMutationPersistenceFaultTests', 'AtlasOperationJournalTests', 'AtlasMutationCoordinatorTests', 'AtlasRecoveryCrashTests', 'AtlasRecoveryExecutorTests', 'AtlasWorkspaceCorruptionTests', 'AtlasProcessRunnerTests', 'AtlasXPCTransportTests', 'AtlasXPCCompletionTests', 'AtlasFileOrganizerScannerTests', 'AtlasSmartCleanExecutionSupportTests', 'AtlasHelperClientTests'])

def execute(args, log):
    with log.open('w') as output:
        try:
            environment = {**os.environ, "ATLAS_STATE_DIR": str(log.parent / "state"), "ATLAS_STATE_FILE": str(log.parent / "state/workspace-state.json")}
            completed = subprocess.run(args, env=environment, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, timeout=600)
        except (OSError, subprocess.TimeoutExpired) as error:
            print('ATLAS_SECURITY_GATE=NOT_RUN reason=' + str(error), file=sys.stderr)
            raise RuntimeError('command not completed') from error
    if completed.returncode != 0:
        print(log.read_text(errors='replace')[-12000:], file=sys.stderr)
        raise RuntimeError('command failed: ' + ' '.join(args))
    return log.read_text(errors='replace')

def count(kind, output):
    if kind == 'shell':
        if re.search(r'^not ok\b|# SKIP', output, re.M | re.I): raise RuntimeError('failure or skipped security assertion')
        tests = re.findall(r'^ok \d+\b', output, re.M)
        plan = re.search(r'^1\.\.(\d+)\s*$', output, re.M)
        if not plan or len(tests) != int(plan[1]): raise RuntimeError('incomplete TAP')
        return len(tests)
    if kind == 'swift':
        if re.search(r"Test Case .* (?:failed|skipped)|error:|Executed \d+ tests?, with [1-9]\d* failures", output): raise RuntimeError('Swift failures')
        passed = re.findall(r"Test Case '-\[([^ ]+) ([^]]+)\]' passed \(", output)
        classes = {name.split('.')[-1] for name, _ in passed}
        missing = set(SWIFT_FILTER.split('|')) - classes
        if missing: raise NotRunError('Swift critical suites not executed: ' + ','.join(sorted(missing)))
        return len(passed)
    events = []
    for line in output.splitlines():
        try: events.append(json.loads(line))
        except json.JSONDecodeError: raise RuntimeError('unrecognized Go JSON')
    if any(e.get('Action') in ['fail', 'skip'] for e in events): raise RuntimeError('Go failure')
    required = {'github.com/tw93/mole/internal/safefile', 'github.com/tw93/mole/cmd/safe-remove'}
    counts = {p: sum(e.get('Action') == 'pass' and bool(e.get('Test')) and e.get('Package') == p for e in events) for p in required}
    if not all(counts.values()): raise NotRunError('Go package has zero assertions')
    return sum(counts.values())

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--component', choices=['shell', 'swift', 'go', 'all'], default='all')
    options = parser.parse_args(); selected = ['shell', 'swift', 'go'] if options.component == 'all' else [options.component]
    commands = {'shell': ['bats', '--formatter', 'tap', *SHELL_CASES], 'swift': ['swift', 'test', '--package-path', 'Packages', '--filter', SWIFT_FILTER], 'go': ['go', 'test', '-race', '-json', './internal/safefile', './cmd/safe-remove']}
    total = 0
    logs = Path(tempfile.mkdtemp(prefix='atlas-security-gate-'))
    print('Security logs: ' + str(logs), flush=True)
    try:
        for component in selected:
            dependencies = {'shell': ['bats', 'shellcheck'], 'swift': ['swift'], 'go': ['go']}[component]
            if any(shutil.which(tool) is None for tool in dependencies):
                print('ATLAS_SECURITY_GATE=NOT_RUN component=' + component, file=sys.stderr); return 2
            if component == 'swift':
                execute(['swift', 'build', '--package-path', 'Testing', '--product', 'AtlasRecoveryCrashHarness'], logs / 'crash-harness-build.log')
            if component == 'shell':
                execute(['./scripts/atlas/sync-mole-runtime.sh', '--check'], logs / 'parity.log')
                execute(['shellcheck', '--rcfile', str(ROOT / '.shellcheckrc'), 'lib/manage/pam_transaction.sh', 'scripts/atlas/security-regression.sh', 'scripts/atlas/verify-pam-vm.sh', 'scripts/atlas/verify-filesystem-vm.sh'], logs / 'lint.log')
            number = count(component, execute(commands[component], logs / (component + '.log')))
            if number == 0: raise NotRunError('zero executed assertions: ' + component)
            total += number
            print(f'ATLAS_SECURITY_GATE=PASS component={component} tests={number}', flush=True)
        if options.component == 'all': print(f'ATLAS_SECURITY_GATE=PASS component=all tests={total}')
        return 0
    except NotRunError as error:
        print('ATLAS_SECURITY_GATE=NOT_RUN reason=' + str(error), file=sys.stderr); return 2
    except RuntimeError as error:
        print('ATLAS_SECURITY_GATE=FAIL reason=' + str(error), file=sys.stderr); return 1

if __name__ == '__main__': sys.exit(main())
