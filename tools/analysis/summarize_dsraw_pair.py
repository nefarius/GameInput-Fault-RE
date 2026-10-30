"""Summarize private raw/public snapshots without publishing identifiers/report bytes.

The prediction models DsHid.c's radial cutoff and 8-bit * 257 axes, then
the observed public signed-axis conversion. Agreement is consistency evidence,
not proof of a matched report or of effective in-memory configuration.
"""
import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path

FIELDS = ('LeftX', 'LeftY', 'RightX', 'RightY')


def raw_sticks(slot):
    if not slot or slot.get('Status') != 'stable':
        return None
    data = bytes.fromhex(slot['ReportHex'])
    if len(data) != 49 or data[0] != 1:
        return None
    return tuple(data[6:10])


def predict_sticks(raw, settings):
    values = list(raw)
    for offset, side in ((0, 'Left'), (2, 'Right')):
        for axis, index in (('X', offset), ('Y', offset + 1)):
            if settings['FlipAxis'][side + axis]:
                values[index] = 255 - values[index]
        dead_zone = settings['DeadZone' + side]
        if dead_zone['Apply'] and math.hypot(values[offset] - 128, values[offset + 1] - 128) <= dead_zone['PolarValue']:
            values[offset:offset + 2] = [128, 128]
    return tuple(v * 257 - 32768 if i % 2 == 0 else 32767 - v * 257
                 for i, v in enumerate(values))


def stable_bracket(row):
    a, b = row.get('rawBefore'), row.get('rawAfter')
    return bool(a and b and a.get('Status') == b.get('Status') == 'stable'
                and a.get('Index') == b.get('Index')
                and a.get('Sequence') == b.get('Sequence')
                and a['Sequence'] % 2 == 0
                and a.get('ReportHex') == b.get('ReportHex'))


def summarize_phase(rows, settings):
    successful = [r for r in rows if r['sample']['Result'] == 0]
    bracketed = [r for r in successful if stable_bracket(r) and raw_sticks(r['rawBefore']) is not None]
    mismatches = [r for r in bracketed if predict_sticks(raw_sticks(r['rawBefore']), settings)
                  != tuple(r['sample'][f] for f in FIELDS)]
    raw_left = Counter(raw_sticks(r.get('rawBefore'))[:2] for r in rows if raw_sticks(r.get('rawBefore')) is not None)
    public_left = Counter((r['sample']['LeftX'], r['sample']['LeftY']) for r in successful)
    pairs = Counter((raw_sticks(r['rawBefore'])[:2], (r['sample']['LeftX'], r['sample']['LeftY'])) for r in bracketed)
    return {
        'samples': len(rows), 'query_results': dict(Counter(str(r['sample']['Result']) for r in rows)),
        'stable_ipc_bracket_successes': len(bracketed), 'stick_prediction_mismatches': len(mismatches),
        'raw_before_statuses': dict(Counter(r['rawBeforeStatus'] for r in rows)),
        'raw_after_statuses': dict(Counter(r['rawAfterStatus'] for r in rows)),
        'distinct_raw_left_pairs': len(raw_left), 'distinct_public_left_pairs': len(public_left),
        'raw_left_top': [{'xy': xy, 'samples': n} for xy, n in raw_left.most_common(8)],
        'public_left_top': [{'xy': xy, 'samples': n} for xy, n in public_left.most_common(8)],
        'bracketed_left_pairs_top': [{'raw_xy': a, 'public_xy': b, 'samples': n}
                                   for (a, b), n in pairs.most_common(8)],
    }


def load(path):
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('configuration', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    capture = load(args.capture)
    config = load(args.configuration)
    settings = config['Global']['XInput']
    # This predictor does not resolve device overrides or non-XInput modes.
    if config.get('Devices') or config['Global']['HidDeviceMode'] != 'XInput':
        raise ValueError('Expected global XInput settings without device overrides')
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    config_hash = digest(args.configuration)
    if config_hash != capture['metadata']['configBeforeSha256']:
        raise ValueError('Configuration does not match recorded before hash')
    after = load(args.capture.parent / 'after.json')
    operator = load(args.capture.parent / 'operator.json')
    metadata = capture['metadata']
    public_keys = ('architecture', 'build', 'ubr', 'rawScriptSha256', 'nativeScriptSha256', 'scriptSha256',
                   'driverSha256', 'dsHidMiniBackingSha256', 'xinputBackingSha256', 'qpcFrequency')
    result = {
        'evidence_kind': 'dshidmini-raw-public-input-screening', 'observed_date': '2026-10-30',
        'runtime_observed': True, 'identities': {k: metadata[k] for k in public_keys},
        'service_before': metadata['serviceBefore'], 'service_after': after['serviceAfter'],
        'config_before_sha256': config_hash, 'config_after_sha256': after['configAfterSha256'],
        'configuration_unchanged_at_endpoints': config_hash == after['configAfterSha256'],
        'saved_stick_settings': {k: settings[k] for k in ('DeadZoneLeft', 'DeadZoneRight', 'FlipAxis')},
        'ipc_slot': metadata['ipcSlot'], 'public_xinput_slot': metadata['publicXInputSlot'],
        'device_reported_ipc_slots': [{'slot': p.get('slot'), 'error': p.get('error')} for p in metadata['slotProperties']],
        'duration_seconds': capture['elapsedSeconds'], 'samples': capture['sampleCount'],
        'recorder_error': capture['error'], 'operator_report': operator['report'], 'phase_cues': capture['cues'],
        'phases': {phase: summarize_phase([r for r in capture['rows'] if r['phase'] == phase], settings)
                   for phase in ('idle-before', 'left-stick', 'idle-after')},
        'raw_provenance': {name: digest(args.capture.parent / name)
                           for name in ('capture.json', 'ready.json', 'after.json', 'operator.json')},
        'limitations': capture['limitations'] + [
            'Prediction uses saved global settings, not a readback of effective driver configuration.',
            'The physical device reports IPC slot 1; its association with public XInput slot 0 is not independently proved.',
            'Agreement across stable brackets does not establish exact same-report causality or explain an earlier separate callback.',
            'Endpoint service/configuration checks are not continuous monitoring. No FPS or vibration measurement.',
            'Counts are sampled observations, not report counts, input-transition counts or queued completions.'],
    }
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    main()
