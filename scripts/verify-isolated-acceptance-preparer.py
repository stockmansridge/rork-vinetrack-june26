#!/usr/bin/env python3
"""Synthetic, offline regression assertions for the fixture preparer only."""
import copy
import importlib.util
from pathlib import Path
from uuid import uuid4

spec = importlib.util.spec_from_file_location('acceptance_preparer', Path(__file__).with_name('prepare-isolated-read-only-acceptance.py'))
preparer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preparer)


def main():
    fixture = {
        'project_ref': 'abcdefghijklmnopqrst', 'fixture_label': 'synthetic-offline-selfcheck',
        'accounts': {'operator': str(uuid4()), 'isolation': str(uuid4())},
        'vineyards': {'A': str(uuid4()), 'B': str(uuid4())},
        'records': {}, 'attachments': [], 'login_method': 'interactive_test_user_login',
        'states': {}, 'transitions': {}, 'contract': {},
        'isolation': {key: True for key in preparer.requirements()['isolation_fields']},
    }
    for scope, names in [('A', preparer.A_RECORDS), ('B', preparer.B_RECORDS)]:
        fixture['records'][scope] = {name: {'id': str(uuid4()), 'vineyard_id': fixture['vineyards'][scope], 'relation': 'synthetic_fixture_only'} for name in names}
    maintenance = fixture['records']['A']['maintenance']
    fixture['attachments'] = [{'bucket': 'vineyard-maintenance-photos', 'path': f"{maintenance['vineyard_id']}/maintenance/{maintenance['id']}/photo.jpg", 'record_id': maintenance['id'], 'vineyard_id': maintenance['vineyard_id']}]
    for name in ('writable', 'read_only', 'reactivated'):
        fixture['states'][name] = {'can_enter_vineyard': True, 'can_write': name != 'read_only', 'read_only_reason': 'trial_expired' if name == 'read_only' else None}
    fixture['transitions'] = {'controlled_scope': fixture['vineyards']['A'], 'method': 'offline assertion only', 'proof_reference': 'not live evidence', 'requires_server_change': False}
    fixture['contract'] = {key: 'offline assertion only' for key in preparer.requirements()['contract_fields']}
    fixture['contract']['read_only_code'] = 'VT_READ_ONLY'
    assert preparer.validate(fixture) is fixture
    assert len(preparer.cases()) == 23
    mutations = [
        lambda f: f['records']['A']['maintenance'].update(vineyard_id=f['vineyards']['B']),
        lambda f: f['attachments'][0].update(path=f['attachments'][0]['path'] + '?foreign=1'),
        lambda f: f['attachments'][0].update(record_id=str(uuid4())),
        lambda f: f['states']['reactivated'].update(can_write=False),
        lambda f: f['transitions'].update(controlled_scope=f['vineyards']['B']),
        lambda f: f['transitions'].update(requires_server_change=None),
        lambda f: f['isolation'].update(no_customer_references=False),
        lambda f: f.update(service_role_key='forbidden-not-real'),
    ]
    for mutation in mutations:
        invalid = copy.deepcopy(fixture)
        mutation(invalid)
        try:
            preparer.validate(invalid)
        except ValueError:
            continue
        raise AssertionError('Unsafe fixture was accepted')
    print('PASS: offline valid schema, exact 23-case ledger and 8 fail-closed controls; 0 authenticated requests')


if __name__ == '__main__':
    main()
