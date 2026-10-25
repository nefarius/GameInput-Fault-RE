"""Make a small reviewed summary from an actual wrapper observation.

Requires the same explicit experiment-context JSON as convert_native.py.
No upload, mutation, or implicit diagnosis; this cannot certify a workaround.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'analysis'))
from convert_native import convert
from compare_captures import summarize, _loads


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw', type=Path, required=True)
    parser.add_argument('--context', type=Path, required=True)
    parser.add_argument('--controller', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    raw = args.raw.read_bytes()
    records = [_loads(line) for line in raw.decode('utf-8-sig').splitlines() if line.strip()]
    context = _loads(args.context.read_text(encoding='utf-8-sig'))
    controller = _loads(args.controller.read_text(encoding='utf-8-sig'))
    pids = sorted({record['target']['pid'] for record in records if record.get('kind') == 'snapshot'})
    if not pids:
        raise ValueError('No measured snapshots; no result can be inferred.')
    loads = [r['details']['probe_sha256'] for r in records if isinstance(r.get('details'), dict) and 'probe_sha256' in r['details']]
    if not loads or any(h != context['probe_sha256'] for h in loads):
        raise ValueError('Probe identity does not match preflight evidence.')
    summaries = []
    for pid in pids:
        normalized = convert(records, context, pid)
        summary = summarize(normalized)
        summary['implementation'] = normalized['metadata']['implementation']
        summary['module_sha256'] = normalized['metadata']['module_sha256']
        summaries.append(summary)
    samples = controller['samples']
    report = {
        'schema_version': 1,
        'experiment': context,
        'source_sha256': {
            'research_jsonl': hashlib.sha256(raw).hexdigest(),
            'controller_json': hashlib.sha256(args.controller.read_bytes()).hexdigest(),
            'context_json': hashlib.sha256(args.context.read_bytes()).hexdigest(),
        },
        'controller': {'start_utc': controller['startUtc'], 'duration_seconds': controller['durationSeconds'],
                       'sample_count': len(samples), 'distinct_packet_values': len({s['packet'] for s in samples if s['result'] == 0}),
                       'rumble_requested': controller['rumbleRequested']},
        'processes': summaries,
        'causal_fault_proven': False,
        'mitigation_validated': False,
        'limitations': [
            'This is observation, not a baseline/mitigation pair.',
            'Pending counts describe submissions returning ERROR_IO_PENDING, not the contents or lifetime of pending requests.',
            'The hook adds counters, locks, and CPU/QPC housekeeping overhead.',
            'Controller packet changes confirm activity, not absence of missed transitions or an input-latency bound.',
            'No simultaneous WPR trace was captured for this observation; correlate a symptomatic trace before causal claims.',
            'No matching calls in a process does not prove that it performed no other work.',
            'The output does not infer that all GameInput reports have one cause or that untested systems are unaffected.'
        ]
    }
    if args.output.resolve() in {p.resolve() for p in (args.raw,args.context,args.controller)}:
        raise ValueError('Output would overwrite input evidence.')
    args.output.write_text(json.dumps(report, indent=2, allow_nan=False)+'\n', encoding='utf-8')
    print(json.dumps([{'pid':p['process_id'],'seconds':p['duration_seconds'],'calls':p['counter_deltas']['calls'],
                       'pending':p['counter_deltas']['pending'],'unchanged':p['counter_deltas']['unchanged'],
                       'cpu_one_core_percent':p['cpu_one_core_percent']} for p in summaries], indent=2))


if __name__ == '__main__':
    main()
