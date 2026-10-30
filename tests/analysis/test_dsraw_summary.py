"""Check cutoff boundary and missing/error exclusions in raw/public analysis."""
import importlib.util
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[2] / 'tools/analysis/summarize_dsraw_pair.py'
SPEC = importlib.util.spec_from_file_location('dsraw_summary', PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SETTINGS = {'DeadZoneLeft': {'Apply': True, 'PolarValue': 2.5492957746478875},
            'DeadZoneRight': {'Apply': True, 'PolarValue': 2.5492957746478875},
            'FlipAxis': dict.fromkeys(('LeftX', 'LeftY', 'RightX', 'RightY'), False)}


class DsRawSummaryTests(unittest.TestCase):
    def test_cutoff_changes_both_axes_and_does_not_rescale_outside(self):
        self.assertEqual(MODULE.predict_sticks((129, 130, 127, 126), SETTINGS), (128, -129, 128, -129))
        self.assertEqual(MODULE.predict_sticks((129, 131, 127, 126), SETTINGS), (385, -900, 128, -129))
        self.assertEqual(MODULE.predict_sticks((133, 129, 128, 128), SETTINGS), (1413, -386, 128, -129))

    def test_exact_radius_boundary_is_inside(self):
        settings = dict(SETTINGS, DeadZoneLeft={'Apply': True, 'PolarValue': 5})
        self.assertEqual(MODULE.predict_sticks((131, 132, 128, 128), settings), (128, -129, 128, -129))

    def test_error_and_unstable_rows_do_not_count_as_prediction_agreement(self):
        raw = bytes([1] + [0]*5 + [129, 130, 127, 126] + [0]*39).hex()
        slot = {'Status': 'stable', 'Sequence': 2, 'Index': 1, 'ReportHex': raw}
        sample = dict(zip(MODULE.FIELDS, (128, -129, 128, -129)), Result=0)
        row = {'rawBefore': slot, 'rawAfter': slot, 'sample': sample,
               'rawBeforeStatus': 'mapped-read-only', 'rawAfterStatus': 'mapped-read-only'}
        error = dict(row, sample={'Result': 1167})
        unstable = dict(row, rawAfter=dict(slot, Sequence=4))
        summary = MODULE.summarize_phase([row, error, unstable], SETTINGS)
        self.assertEqual(summary['samples'], 3)
        self.assertEqual(summary['query_results'], {'0': 2, '1167': 1})
        self.assertEqual(summary['stable_ipc_bracket_successes'], 1)
        self.assertEqual(summary['stick_prediction_mismatches'], 0)


if __name__ == '__main__':
    unittest.main()
