"""Exercise storage preflight with isolated synthetic metadata and inert files."""

import json
import pathlib
import plistlib
import re

from verify import digest, run_stage


def storage_checks(executable, repo, package, targets, directory, env, output, redactor):
    home = pathlib.Path(directory) / 'synthetic-home'
    home.mkdir()
    isolated = dict(env, CFFIXED_USER_HOME=str(home))
    probe = (
        'import Foundation; import Darwin; '
        'let expected = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]; '
        'exit(FileManager.default.homeDirectoryForCurrentUser.path == expected ? 0 : 40)'
    )
    isolation = run_stage(
        'storage-home-isolation',
        ['xcrun', 'swift', '-module-cache-path', str(pathlib.Path(directory) / 'module-cache'), '-e', probe],
        repo, isolated, output, redactor, 60
    )
    if isolation['exitCode'] != 0:
        return {'passed': False, 'status': 'environment_not_verified',
                'reason': 'synthetic Foundation home isolation was not established',
                'realGuestExecuted': False}

    identifiers = {target['buildSettings'].get('PRODUCT_BUNDLE_IDENTIFIER') for target in targets}
    for source in package.glob('Sources/**/Bundle+Extensions.swift'):
        identifiers.update(re.findall(r'Bundle\.main\.bundleIdentifier\s*\?\?\s*"([^"]+)"', source.read_text()))
    identifiers.discard(None)
    identifiers.discard('')
    if not identifiers:
        return {'passed': False, 'status': 'fixture_setup_failed', 'realGuestExecuted': False}

    bottle = pathlib.Path(directory) / 'synthetic-bottle'
    bottle.mkdir()
    metadata = bottle / 'Metadata.plist'
    metadata.write_bytes(plistlib.dumps({}))
    installer = pathlib.Path(directory) / 'fixture-installer.exe'
    installer.write_bytes(b'inert synthetic preflight fixture; never executable\n')
    target = pathlib.Path(directory) / 'synthetic-staging'
    target.mkdir()
    registries = []
    for identifier in identifiers:
        registry = home / 'Library/Containers' / identifier / 'BottleVM.plist'
        registry.parent.mkdir(parents=True, exist_ok=True)
        registries.append(registry)
    registry_encoder = (
        'import Foundation; '
        'struct V: Encodable { let major = 1; let minor = 0; let patch = 0; '
        'let preRelease = ""; let build = "" }; '
        'struct R: Encodable { let fileVersion = V(); let paths: [URL] }; '
        'let encoder = PropertyListEncoder(); encoder.outputFormat = .xml; '
        'let data = try encoder.encode(R(paths: [URL(fileURLWithPath: CommandLine.arguments[1])])); '
        'for path in CommandLine.arguments.dropFirst(2) { try data.write(to: URL(fileURLWithPath: path)) }'
    )
    encoded = run_stage('storage-fixture-registry',
                        ['xcrun', 'swift', '-module-cache-path', str(pathlib.Path(directory) / 'module-cache'),
                         '-e', registry_encoder, str(bottle), *map(str, registries)],
                        repo, isolated, output, redactor, 60)
    if encoded['exitCode'] != 0:
        return {'passed': False, 'status': 'fixture_setup_failed', 'realGuestExecuted': False}
    encoded_registry = plistlib.loads(registries[0].read_bytes())
    registry_url_is_keyed = isinstance(encoded_registry['paths'][0], dict)
    protected = [metadata, installer, *registries]
    before = {path: digest(path.read_bytes()) for path in protected}
    invalid_config = pathlib.Path(directory) / 'invalid-guest-config.json'
    invalid_config.write_text('{invalid json}')
    base = [str(executable), 'storage-preflight', '--bottle-path']
    cases = [
        ('storage-local-capacity', target, installer, []),
        ('storage-file-target', installer, installer, []),
        ('storage-missing-installer', target, pathlib.Path(directory) / 'missing-installer.exe', []),
        ('storage-invalid-guest-config', target, installer, ['--guest-config', str(invalid_config)]),
    ]
    checks = {}
    expected_keys = {'version', 'state', 'isWritable', 'hasTargetDirectory', 'availableBytes',
                     'installerBytes', 'reservedBytes', 'requiredBytes', 'guestMapping'}
    guest_config_errors = {'The guest configuration could not be read. Check that it is a valid JSON file.'}
    for catalog in repo.glob('*/Localizable.xcstrings'):
        translations = json.loads(catalog.read_text()).get('strings', {}).get(
            'runtime.cli.storageGuestConfigInvalid', {}).get('localizations', {})
        guest_config_errors.update(item.get('stringUnit', {}).get('value', '')
                                   for item in translations.values())
    guest_config_errors.discard('')
    for name, selected_target, selected_installer, extra in cases:
        result = run_stage(name, [*base, '--target', str(selected_target), *extra,
                                  str(bottle), str(selected_installer)],
                           repo, isolated, output, redactor, 20)
        text = (output / (name + '.log')).read_text()
        if name == 'storage-invalid-guest-config':
            checks[name] = {'exitCode': result['exitCode'],
                            'passed': result['exitCode'] == 1 and bool(text.strip())
                            and 'Missing expected argument' not in text
                            and 'Unknown option' not in text
                            and any(error in text for error in guest_config_errors)
                            and '"version"' not in text}
            continue
        try:
            payload = json.loads(text)
        except (ValueError, TypeError):
            checks[name] = {'exitCode': result['exitCode'], 'passed': False,
                            'reason': 'one complete JSON preflight report required'}
            continue
        if not isinstance(payload, dict):
            checks[name] = {'exitCode': result['exitCode'], 'passed': False,
                            'reason': 'JSON object required'}
            continue
        valid = isinstance(payload, dict) and set(payload) == expected_keys
        valid = valid and payload.get('version') == 1 and payload.get('hasTargetDirectory') is True
        valid = valid and payload.get('guestMapping') == 'notConfigured'
        if name == 'storage-local-capacity':
            available = payload.get('availableBytes')
            required = payload.get('requiredBytes')
            valid = valid and payload.get('installerBytes') == installer.stat().st_size
            valid = valid and isinstance(available, int) and isinstance(required, int)
            valid = valid and required == installer.stat().st_size + payload.get('reservedBytes', -1)
            expected_state = 'ready' if isinstance(available, int) and isinstance(required, int) and available >= required else 'insufficientSpace'
            valid = valid and payload.get('isWritable') is True and payload.get('state') == expected_state
        elif name == 'storage-file-target':
            valid = valid and payload.get('state') == 'notWritable' and payload.get('isWritable') is False
        else:
            valid = valid and payload.get('state') == 'notChecked'
            valid = valid and payload.get('installerBytes') is None and payload.get('requiredBytes') is None
        expected_exit = 0 if payload.get('state') == 'ready' else 1
        checks[name] = {'exitCode': result['exitCode'], 'state': payload.get('state'),
                        'guestMapping': payload.get('guestMapping'),
                        'passed': valid and result['exitCode'] == expected_exit}

    preservation = {
        'metadataRegistryAndInstallerUnchanged': all(digest(path.read_bytes()) == value for path, value in before.items()),
        'savedProgramSettingsNotCreated': not (bottle / 'Program Settings').exists(),
        'noPersistentStagingFiles': not list(target.iterdir()),
    }
    return {'passed': all(check['passed'] for check in checks.values()) and all(preservation.values()),
            'status': 'synthetic_local_execution', 'homeIsolationVerified': True,
            'registryEncoding': 'Foundation PropertyListEncoder',
            'registryURLUsesKeyedRepresentation': registry_url_is_keyed,
            'bundleIdentifiersFrom': 'scheme/all-target build settings and source fallback; identifiers not exported',
            'syntheticBottleLookupResolved': checks['storage-local-capacity']['passed'],
            'checks': checks, 'preservation': preservation, 'fixtureInstallerExecuted': False,
            'realGuestExecuted': False, 'realInstallationVerified': False,
            'scope': 'temporary synthetic registry, inert installer and local staging; capacity pass is not guest mapping or installation proof'}
