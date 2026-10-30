"""Review a private single-outstanding queued-state capture without device paths/PIDs."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import statistics


def summarize_requests(capture):
    rows = capture['Requests']
    successful = []
    violations = []
    for row in rows:
        value = row.get('OutputHex')
        if row['Success'] and row['Bytes'] == 24 and value is not None:
            payload = bytes.fromhex(value)
            if len(payload) != 24:
                raise ValueError('Malformed successful output')
            successful.append((row, payload))
        elif value is not None:
            violations.append(row['Index'])
    pairs = list(zip(successful, successful[1:]))
    changed = Counter(i for (_, a), (_, b) in pairs for i in range(24) if a[i] != b[i])
    packets = [int.from_bytes(b[:2], 'little') for _, b in successful]
    lifetimes = [(r['CompletionObservedQpc'] - r['SubmittedQpc']) / capture['Frequency']
                 for r, _ in successful]
    phases = {}
    for name, low, high in [('idle-before', 0, 20), ('left-stick', 20, 25), ('idle-after', 25, 35)]:
        submitted = [r for r in rows if low <= (r['SubmittedQpc'] - capture['StartQpc']) / capture['Frequency'] < high]
        completed = [r for r, _ in successful if low <= (r['CompletionObservedQpc'] - capture['StartQpc']) / capture['Frequency'] < high]
        phases[name] = {'submissions_by_submission_time': len(submitted),
                        'successes_by_observed_completion_time': len(completed)}
    cancelled = [r for r in rows if r['CancelRequested']]
    return {
        'requests': len(rows), 'initial_pending_returns': sum(r['PendingReturn'] for r in rows),
        'successful_exact_24_byte_completions': len(successful),
        'completion_error_counts': dict(Counter(str(r['CompletionError']) for r in rows)),
        'cancel_requested': len(cancelled), 'cleanup_pending': capture['CleanupPending'],
        'device_closed': capture['Closed'], 'device_close_error': capture['CloseError'],
        'device_close_seconds': capture['CloseTicks'] / capture['Frequency'], 'recorder_error': capture['Error'],
        'duration_seconds': (capture['EndQpc'] - capture['StartQpc']) / capture['Frequency'],
        'adjacent_successful_pairs': len(pairs),
        'adjacent_equal_all_24_bytes': sum(a == b for (_, a), (_, b) in pairs),
        'adjacent_equal_excluding_packet_word': sum(a[2:] == b[2:] for (_, a), (_, b) in pairs),
        'changed_byte_counts': dict(sorted(changed.items())),
        'packet_first': packets[0] if packets else None, 'packet_last': packets[-1] if packets else None,
        'packet_delta_modulo_65536_counts': dict(Counter(str((b-a) % 65536) for a, b in zip(packets, packets[1:]))),
        'successful_submission_to_observation_seconds': {
            'minimum': min(lifetimes) if lifetimes else None,
            'median': statistics.median(lifetimes) if lifetimes else None,
            'maximum': max(lifetimes) if lifetimes else None},
        'cancelled_requests': [{'submission_elapsed_seconds': (r['SubmittedQpc'] - capture['StartQpc']) / capture['Frequency'],
            'observed_lifetime_seconds': (r['CompletionObservedQpc'] - r['SubmittedQpc']) / capture['Frequency'] if r['CompletionObservedQpc'] else None,
            'completion_error': r['CompletionError'], 'cancel_error': r['CancelError'], 'cleanup_pending': r['CleanupPending']}
            for r in cancelled],
        'phases_by_nominal_time_windows': phases, 'output_access_contract_violations': violations,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    load = lambda p: json.loads(p.read_text(encoding='utf-8-sig'))
    data = load(args.capture)
    metadata = data['metadata']
    result = {'evidence_kind': 'direct-queued-state-completion-screening', 'observed_date': '2026-10-30',
              'runtime_observed': True,
              'metadata': {k: v for k, v in metadata.items() if k not in ('processId', 'devicePath', 'readyUtc')},
              'measurements': summarize_requests(data['capture']), 'phase_cues': data['capture']['Cues'],
              'operator_report': load(args.capture.parent / 'operator.json')['report'],
              'service_after': load(args.capture.parent / 'after.json')['serviceAfter'],
              'provenance': {name: hashlib.sha256((args.capture.parent / name).read_bytes()).hexdigest()
                             for name in ('capture.json', 'ready.json', 'operator.json', 'after.json')},
              'limitations': data['limitations'] + [
                  'No first-success comparison baseline. Adjacent success comparisons exclude failed/cancelled rows.',
                  'Full-payload equality excluding the packet word does not decode every private field.',
                  'Submission and observed-completion windows are separate; pending requests can cross phase boundaries.',
                  'Endpoint service checks are not continuous monitoring; controller configuration was not rehashed in this recording.',
                  'Initial device lifetime/population and correction status require separate debugger evidence; no game workload was measured.']}
    with args.output.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')


if __name__ == '__main__':
    main()
