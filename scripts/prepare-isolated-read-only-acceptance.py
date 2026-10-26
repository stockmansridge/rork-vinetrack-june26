#!/usr/bin/env python3
"""Offline-only, fail-closed preparation for the supplied 23-case acceptance.

No HTTP client, authentication, credentials, endpoint inference or backend mutations.
Supplied identifiers are an allowlist, never a request to discover production data.
Use --requirements to see the non-secret fixture contract; --fixture validates it.
A validated worklist is preparation, not execution or native completeness.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from uuid import UUID

ROOT = Path(__file__).resolve().parents[1]
REPORT = ROOT / 'docs/reviews/final-mobile-acceptance-legacy-save-recovery-2026-10-15.md'
A_RECORDS = (
    'block', 'completed_spray', 'completed_trip', 'completed_tank',
    'planned_spray', 'active_spray', 'active_trip', 'active_tank',
    'gps_evidence', 'pin', 'growth', 'maintenance', 'fertigation',
    'resistance', 'scouting',
)
B_RECORDS = ('block', 'pin', 'maintenance')
TOP_KEYS = {'project_ref', 'fixture_label', 'accounts', 'vineyards', 'records',
            'attachments', 'login_method', 'states', 'transitions', 'contract', 'isolation'}


def cases():
    text = REPORT.read_text()
    start = text.index('### G. Exact23-case acceptance ledger')
    end = text.index('### H.', start)
    found = re.findall(r'^(\d+)\. \*\*(.*?) — ', text[start:end], flags=re.M)
    if [int(n) for n, _ in found] != list(range(1, 24)):
        raise ValueError('Authoritative case ledger missing or reordered; no substitute generated')
    return [{'number': int(n), 'case': title} for n, title in found]


def uuid(value):
    if not isinstance(value, str) or str(UUID(value)) != value:
        raise ValueError('Fixture UUIDs must be explicit canonical identifiers')
    return value


def require(condition, message):
    if not condition:
        raise ValueError(message)


def reject_credentials(value):
    if isinstance(value, dict):
        for key, item in value.items():
            require(not re.search(r'password|secret|token|service.?role|credential|api.?key|anon.?key', key, re.I),
                    'Credentials/keys are not accepted in fixture files')
            reject_credentials(item)
    elif isinstance(value, list):
        for item in value:
            reject_credentials(item)
    elif isinstance(value, str):
        require(not value.startswith(('eyJ', 'sb_secret_', 'sb_publishable_')), 'Do not embed authentication material')


def validate(fixture):
    require(set(fixture) == TOP_KEYS, 'Fixture fields must exactly match --requirements')
    reject_credentials(fixture)
    require(re.fullmatch(r'[a-z0-9]{20}', fixture['project_ref']) is not None, 'Explicit Supabase project identifier required')
    require(fixture['fixture_label'].startswith('synthetic-'), 'Explicit synthetic fixture label required')
    require(set(fixture['accounts']) == {'operator', 'isolation'}, 'Two ordinary synthetic test-user IDs required')
    require(set(fixture['vineyards']) == {'A', 'B'}, 'Exact synthetic vineyard A/B identifiers required')
    identities = [uuid(v) for group in ('accounts', 'vineyards') for v in fixture[group].values()]
    require(len(set(identities)) == 4, 'Accounts and vineyards must have distinct IDs')
    require(fixture['login_method'] in ('interactive_test_user_login', 'existing_short_lived_test_session'), 'Test-user login method required; no elevated access')
    require(set(fixture['records']) == {'A', 'B'}, 'Records must belong only to A/B')
    record_ids = []
    for scope, names in [('A', A_RECORDS), ('B', B_RECORDS)]:
        rows = fixture['records'][scope]
        require(set(rows) == set(names), f'Exact {scope} record inventory required')
        for name, row in rows.items():
            require(set(row) == {'id', 'vineyard_id', 'relation'}, f'{scope}/{name}: exact row identity required')
            record_ids.append(uuid(row['id']))
            require(row['vineyard_id'] == fixture['vineyards'][scope], f'{scope}/{name}: foreign vineyard forbidden')
            require(re.fullmatch(r'[a-z][a-z0-9_]*', row['relation']) is not None, 'Delivered relation name required, not a URL/query')
    require(len(set(record_ids)) == len(record_ids), 'Every fixture record must have a unique ID')
    require(fixture['attachments'], 'Explicit synthetic attachment paths required')
    for attachment in fixture['attachments']:
        require(set(attachment) == {'bucket', 'path', 'record_id', 'vineyard_id'}, 'Exact attachment identity required')
        require(attachment['record_id'] in record_ids, 'Attachment parent outside allowlisted records')
        require(attachment['vineyard_id'] in fixture['vineyards'].values(), 'Attachment vineyard outside fixture')
        require(re.fullmatch(r'[a-z0-9-]+', attachment['bucket']) is not None, 'Literal bucket name required')
        path = attachment['path']
        require(path.startswith(attachment['vineyard_id'] + '/') and all(p not in ('', '.', '..') for p in path.split('/')) and not any(c in path for c in '?%#\\'), 'Non-canonical or foreign object path forbidden')
        parent = next(row for group in fixture['records'].values() for row in group.values() if row['id'] == attachment['record_id'])
        require(parent['vineyard_id'] == attachment['vineyard_id'], 'Attachment parent vineyard mismatch')
    require(set(fixture['states']) == {'writable', 'read_only', 'reactivated'}, 'All three authoritative states required')
    for name, writable in [('writable', True), ('read_only', False), ('reactivated', True)]:
        state = fixture['states'][name]
        require(state.get('can_enter_vineyard') is True and state.get('can_write') is writable,
                f'{name}: explicit capability contract required')
        require(state.get('read_only_reason') == (None if writable else 'trial_expired'), f'{name}: explicit reason contract required')
    contract = fixture['contract']
    require(contract.get('read_only_code') == 'VT_READ_ONLY', 'Structured denial contract required')
    require(all(contract.get(k) for k in ('capability_reference', 'receipt_reference', 'storage_error_reference', 'state_readback_reference')), 'Delivered capability/receipt/storage/readback contract references required')
    transitions = fixture['transitions']
    require(transitions.get('controlled_scope') == fixture['vineyards']['A'], 'State controls must be limited to synthetic A')
    require(transitions.get('method') and transitions.get('proof_reference'), 'Approved state-control and authoritative readback required; never invent an endpoint')
    require(type(transitions.get('requires_server_change')) is bool, 'Whether server changes are required must be confirmed, not assumed')
    isolation = fixture['isolation']
    for key in ('synthetic_only', 'no_customer_memberships', 'no_customer_references', 'side_effects_isolated', 'approved_project'):
        require(isolation.get(key) is True, f'Explicit isolation confirmation required: {key}')
    return fixture


def requirements():
    return {
        'required_fixture_fields': sorted(TOP_KEYS),
        'record_inventory': {'A': A_RECORDS, 'B': B_RECORDS},
        'row_fields': ['id', 'vineyard_id', 'relation'],
        'attachment_fields': ['bucket', 'path', 'record_id', 'vineyard_id'],
        'accounts': {'operator': 'ordinary synthetic manager in A/B, not vineyard owner or System Admin',
                     'isolation': 'ordinary synthetic manager in B only, no membership of A'},
        'login_methods': ['interactive_test_user_login', 'existing_short_lived_test_session'],
        'states': ['writable', 'read_only', 'reactivated'],
        'contract_fields': ['read_only_code', 'capability_reference', 'receipt_reference', 'storage_error_reference', 'state_readback_reference'],
        'transition_fields': ['controlled_scope', 'method', 'proof_reference', 'requires_server_change'],
        'isolation_fields': ['synthetic_only', 'no_customer_memberships', 'no_customer_references', 'side_effects_isolated', 'approved_project'],
        'cases': cases(),
        'safety': 'No secrets, owner login, service-role access or authenticated execution. Relations, controls and receipt schema must be delivered, not inferred.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--requirements', action='store_true')
    group.add_argument('--fixture', type=Path)
    args = parser.parse_args()
    if args.requirements:
        print(json.dumps(requirements(), indent=2))
        return 0
    try:
        raw = args.fixture.read_bytes()
        fixture = validate(json.loads(raw))
        result = {'status': 'OFFLINE_FIXTURE_VALIDATED_NOT_EXECUTED',
                  'fixture_sha256': hashlib.sha256(raw).hexdigest(),
                  'project_ref': fixture['project_ref'],
                  'authenticated_requests': 0,
                  'native_completeness': 'NOT_ESTABLISHED',
                  'worklist': [{**case, 'ios': 'NOT_EXECUTED', 'android': 'NOT_EXECUTED',
                                'required_evidence': 'Owning test-account/vineyard, fresh capability/state readback, exact allowlisted row/object before-after snapshots, original queue/receipt/retry evidence; UI evidence for history cases'} for case in cases()]}
        print(json.dumps(result, indent=2))
        return 0
    except (ValueError, KeyError, TypeError, OSError) as error:
        print(json.dumps({'status': 'BLOCKED_INVALID_OR_INCOMPLETE_FIXTURE', 'reason': str(error), 'authenticated_requests': 0}))
        return 2


if __name__ == '__main__':
    sys.exit(main())
