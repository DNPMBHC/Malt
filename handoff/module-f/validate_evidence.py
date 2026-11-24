#!/usr/bin/env python3
"""Validate the isolated module-f evidence snapshot without network or dependencies."""
import argparse
import copy
import datetime as dt
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit


OFFICIAL_HOSTS = {
    'support.riotgames.com', 'developer.riotgames.com', 'playvalorant.com',
    'val.qq.com', 'www.leagueoflegends.com', 'www.riotgames.com',
    'store.steampowered.com', 'id.embark.games', 'thefinals-jp.nexon.com',
    'www.reachthefinals.com', 'www.nexon.co.jp', 'support.microsoft.com',
    'www.embark-studios.com',
    'lol.qq.com', 'kb.parallels.com',
    'api.val.qq.com', 'ossweb-img.qq.com', 'gamesafe.qq.com', 'thefinals.qq.com',
    'learn.microsoft.com',
}
STATE_FIELDS = ('publisher_permission', 'publisher_support', 'driver_load',
                'game_start', 'protected_session')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def indexed(items, key):
    require(isinstance(items, list), key + ': collection must be an array')
    result = {}
    for item in items:
        value = item.get(key)
        require(isinstance(value, str) and value not in result,
                key + ': missing or duplicate identifier')
        result[value] = item
    return result


def valid_date(value, label, cutoff):
    require(isinstance(value, str), label + ': date must be a string')
    parsed = dt.date.fromisoformat(value)
    require(parsed <= cutoff, label + ': future date relative to snapshot')


def validate(data):
    require(data['schema_version'] == '1.0.0', 'unsupported schema version')
    snapshot = data['snapshot']
    cutoff = dt.date.fromisoformat(snapshot['as_of'])
    require(snapshot['timezone'] == 'Asia/Shanghai', 'snapshot timezone')
    require(snapshot['live_client_tested'] is False, 'this snapshot contains no live tests')
    require(snapshot['vendor_contacted'] is False, 'this snapshot contains no vendor contact')
    require(snapshot['accounts_used'] is False, 'this snapshot contains no account use')
    products = indexed(data['products'], 'target_id')
    require(set(products) == {'target-a', 'target-b', 'target-c'}, 'three independent targets required')
    sources = indexed(data['sources'], 'source_id')
    scopes = indexed(data['scopes'], 'scope_id')
    claims = indexed(data['claims'], 'claim_id')
    records = indexed(data['compatibility_matrix'], 'record_id')
    for source_id, source in sources.items():
        require(source['title'] and source['official_scope'] and source['version_scope'], source_id + ': metadata')
        url = urlsplit(source['url'])
        require(url.scheme == 'https' and url.hostname in OFFICIAL_HOSTS, source_id + ': nonofficial URL')
        require(not url.username and not url.password, source_id + ': credentials in URL')
        valid_date(source['accessed_on'], source_id, cutoff)
        require(source['access_timezone'] == 'Asia/Shanghai', source_id + ': access timezone')
        require(source['access_result'] in {'opened', 'opened_partial'}, source_id + ': access result')
        require(bool(source['applicable_scope_ids'])
                and all(scope in scopes for scope in source['applicable_scope_ids']), source_id + ': source scope metadata')
        kind = source['page_date_kind']
        require(kind in {'publication', 'last_updated', 'page_display', 'not_displayed'}, source_id + ': date kind')
        if source['page_date'] is None:
            require(kind == 'not_displayed', source_id + ': missing dated evidence')
        else:
            valid_date(source['page_date'], source_id, cutoff)
            require(kind != 'not_displayed', source_id + ': date classification')
        require(source['published_at'] == (source['page_date'] if kind == 'publication' else None), source_id + ': publication ambiguity')
        require(source['updated_at'] == (source['page_date'] if kind == 'last_updated' else None), source_id + ': update ambiguity')
    for scope_id, scope in scopes.items():
        require(scope['target_id'] in products or scope['target_id'] is None, scope_id + ': target')
        require(scope['platform'] and scope['distribution'] and scope['region'], scope_id + ': scope metadata')
    for claim_id, claim in claims.items():
        require(claim['scope_id'] in scopes, claim_id + ': scope')
        require(claim['status'] in {'confirmed', 'unknown', 'conflict', 'inferred'}, claim_id + ': status')
        valid_date(claim['updated_on'], claim_id, cutoff)
        require(claim['summary_zh'] and claim['limitation_zh'], claim_id + ': qualification')
        require(bool(claim['evidence']), claim_id + ': evidence or reviewed corpus required')
        for evidence in claim['evidence']:
            require(evidence['source_id'] in sources, claim_id + ': dangling source')
            require(claim['scope_id'] in sources[evidence['source_id']]['applicable_scope_ids'],
                    claim_id + ': source does not apply to claim scope')
            require(evidence['locator'] and evidence['paraphrase_zh'], claim_id + ': evidence precision')
        if claim['topic'] == 'driver_binary_architecture':
            require(claim['status'] == 'unknown', claim_id + ': binary has not been inspected')
            for field in ('driver_pe_machine', 'driver_version', 'sha256', 'signature_chain', 'game_executable_machine'):
                require(claim['value'][field] is None, claim_id + ': unverified binary field')
        if claim['topic'] == 'cross_boundary_anticheat_interface':
            require(claim['status'] == 'unknown' and claim['value'] is None, claim_id + ': interface not evidenced')
        if claim['topic'] == 'observed_public_version':
            require(claim['value']['installed_client_build'] is None and claim['value']['driver_version'] is None, claim_id + ': patch is not installed build')
    for record_id, record in records.items():
        require(record['scope_id'] in scopes, record_id + ': scope')
        require(record['environment'] == 'virtual_machine', record_id + ': environment')
        valid_date(record['updated_on'], record_id, cutoff)
        for field in STATE_FIELDS:
            state = record[field]
            valid_date(state['updated_on'], record_id + '/' + field, cutoff)
            allowed = {'allowed', 'prohibited', 'unknown'} if field == 'publisher_permission' else (
                {'supported', 'not_supported', 'unknown', 'conflict'} if field == 'publisher_support'
                else {'unknown', 'passed', 'failed'})
            require(state['value'] in allowed, record_id + ': invalid state vocabulary')
            for claim_id in state['basis_claim_ids']:
                require(claim_id in claims, record_id + ': dangling claim')
                require(claims[claim_id]['scope_id'] == record['scope_id'], record_id + ': cross-region/platform promotion')
            if field in ('driver_load', 'game_start', 'protected_session'):
                require(state['value'] == 'unknown' and state['verification_method'] == 'not_tested'
                        and not state['basis_claim_ids'], record_id + ': untested state promoted')
            elif state['value'] != 'unknown':
                require(bool(state['basis_claim_ids']), record_id + ': policy provenance required')
                for claim_id in state['basis_claim_ids']:
                    require(claims[claim_id]['status'] == 'confirmed', record_id + ': policy not confirmed')
                    require(claims[claim_id]['topic'] in {'vm_publisher_support', 'vm_publisher_permission', 'regional_anticheat_and_vm_policy'}, record_id + ': not a policy claim')
                    if field == 'publisher_permission':
                        require(claims[claim_id]['topic'] == 'vm_publisher_permission', record_id + ': support is not permission')
                        require(state['value'] == claims[claim_id]['value'], record_id + ': permission contradicts source claim')
                    elif claims[claim_id]['topic'] == 'vm_publisher_support':
                        require(state['value'] == claims[claim_id]['value'], record_id + ': support contradicts source claim')
                    elif claims[claim_id]['topic'] == 'regional_anticheat_and_vm_policy':
                        require(state['value'] == 'not_supported'
                                and claims[claim_id]['value'].get('vm_connection') == 'connection_unavailable',
                                record_id + ': regional policy mapping')
                    else:
                        raise ValueError(record_id + ': permission alone is not support evidence')
        binary_id = record['binary_architecture_claim_id']
        if binary_id is not None:
            require(binary_id in claims and claims[binary_id]['scope_id'] == record['scope_id']
                    and claims[binary_id]['topic'] == 'driver_binary_architecture', record_id + ': wrong binary reference')
        if 'cn' in record['scope_id']:
            require(all(record[f]['value'] == 'unknown' for f in STATE_FIELDS), record_id + ': unsupported regional extrapolation')
    for target in products:
        relevant = [c for c in claims.values() if scopes[c['scope_id']]['target_id'] == target]
        require(relevant, target + ': independent evidence missing')
    require(claims['C-KERNEL']['value']['complete_current_stack'] is None, 'current full stack not established')
    require(claims['A-BUILD']['status'] == 'conflict' and claims['A-BUILD']['value']['resolved_minimum'] is None, 'OS conflict unresolved')
    require(claims['B-MAC']['status'] == 'conflict', 'native Mac source conflict unresolved')
    require(records['VM-C-JP']['publisher_permission']['value'] == 'unknown', 'connection limit is not permission prohibition')
    text = json.dumps(data, ensure_ascii=False)
    require(not any(token in text for token in ('/' + 'Users' + '/', '/' + 'home' + '/')) and not re.search('[A-Za-z]:' + re.escape(chr(92)), text), 'private absolute path')
    require(not re.search(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', text), 'email address')
    return {'sources': len(sources), 'claims': len(claims), 'scopes': len(scopes), 'vm_records': len(records)}


def self_test(data):
    mutations = []
    case = copy.deepcopy(data)
    case['compatibility_matrix'][0]['protected_session']['value'] = 'passed'
    mutations.append(('reject_unobserved_session', case))
    case = copy.deepcopy(data)
    case['claims'][0]['evidence'][0]['source_id'] = 'S-MISSING'
    mutations.append(('reject_dangling_source', case))
    case = copy.deepcopy(data)
    case['compatibility_matrix'][1]['publisher_support'] = copy.deepcopy(case['compatibility_matrix'][0]['publisher_support'])
    mutations.append(('reject_cross_region_policy', case))
    case = copy.deepcopy(data)
    case['compatibility_matrix'][0]['publisher_permission'] = copy.deepcopy(case['compatibility_matrix'][0]['publisher_support'])
    case['compatibility_matrix'][0]['publisher_permission']['value'] = 'prohibited'
    mutations.append(('reject_support_to_prohibition', case))
    case = copy.deepcopy(data)
    next(c for c in case['claims'] if c['claim_id'] == 'A-BIN')['value']['driver_pe_machine'] = 'AMD64'
    mutations.append(('reject_uninspected_driver_machine', case))
    case = copy.deepcopy(data)
    case['compatibility_matrix'][0]['binary_architecture_claim_id'] = 'A-VM'
    mutations.append(('reject_nonbinary_reference', case))
    case = copy.deepcopy(data)
    case['compatibility_matrix'][0]['publisher_support']['value'] = 'supported'
    mutations.append(('reject_reversed_support_policy', case))
    case = copy.deepcopy(data)
    next(r for r in case['compatibility_matrix'] if r['record_id'] == 'VM-C-STEAM')['publisher_permission']['value'] = 'allowed'
    mutations.append(('reject_reversed_permission_policy', case))
    case = copy.deepcopy(data)
    next(c for c in case['claims'] if c['claim_id'] == 'B-VM')['evidence'][0]['source_id'] = 'S-C03'
    mutations.append(('reject_cross_scope_source', case))
    for name, case in mutations:
        try:
            validate(case)
        except (ValueError, KeyError, TypeError):
            continue
        raise ValueError('self-test failed: ' + name)
    return len(mutations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    data = json.loads((directory / 'evidence.json').read_text())
    result = validate(data)
    if args.self_test:
        result['negative_semantic_checks'] = self_test(data)
    for path in directory.iterdir():
        if path.suffix not in {'.md', '.json', '.py'}:
            continue
        content = path.read_text()
        require(not re.search(('/' + 'Users' + '/|/' + 'home' + '/'), content), 'private path in deliverable')
    result['result'] = 'passed'
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, json.JSONDecodeError, re.error) as error:
        print('Evidence validation failed: ' + type(error).__name__, file=sys.stderr)
        sys.exit(1)
