"""Separate completion timing, payload equality and cancellation in summaries."""
import importlib.util
from pathlib import Path
import unittest

PATH = Path(__file__).resolve().parents[2] / 'tools/analysis/summarize_queued_state.py'
SPEC = importlib.util.spec_from_file_location('queued_summary', PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class QueuedSummaryTests(unittest.TestCase):
    def row(self, index, packet, start, finish):
        return dict(Index=index, Success=True, Bytes=24, OutputHex=(packet.to_bytes(2, 'little')+bytes(22)).hex(),
                    SubmittedQpc=start, CompletionObservedQpc=finish, PendingReturn=True, CompletionError=0,
                    CancelRequested=False, CleanupPending=False)

    def capture(self, rows):
        return dict(Requests=rows, Frequency=1000, StartQpc=1000, EndQpc=36000,
                    CleanupPending=False, Closed=True, CloseError=0, CloseTicks=1, Error=None)

    def test_wrapped_packet_and_equal_payload_are_separate_from_full_reply(self):
        result = MODULE.summarize_requests(self.capture([self.row(0, 65535, 1000, 2000), self.row(1, 0, 2001, 3000)]))
        self.assertEqual(result['adjacent_equal_all_24_bytes'], 0)
        self.assertEqual(result['adjacent_equal_excluding_packet_word'], 1)
        self.assertEqual(result['packet_delta_modulo_65536_counts'], {'1': 1})

    def test_request_crossing_phase_boundary_and_cancellation_are_not_misclassified(self):
        first = self.row(0, 1, 20000, 22000)
        last = dict(self.row(1, 2, 25000, 36000), Success=False, Bytes=0, OutputHex=None,
                    CancelRequested=True, CompletionError=995, CancelError=0)
        result = MODULE.summarize_requests(self.capture([first, last]))
        self.assertEqual(result['successful_exact_24_byte_completions'], 1)
        self.assertEqual(result['adjacent_successful_pairs'], 0)
        self.assertEqual(result['phases_by_nominal_time_windows']['idle-before']['submissions_by_submission_time'], 1)
        self.assertEqual(result['phases_by_nominal_time_windows']['left-stick']['successes_by_observed_completion_time'], 1)
        self.assertEqual(result['cancelled_requests'][0]['observed_lifetime_seconds'], 11)

    def test_error_output_is_flagged_and_excluded(self):
        row = dict(self.row(0, 1, 1000, 2000), Success=False, CompletionError=5)
        result = MODULE.summarize_requests(self.capture([row]))
        self.assertEqual(result['successful_exact_24_byte_completions'], 0)
        self.assertEqual(result['output_access_contract_violations'], [0])
        self.assertIsNone(result['successful_submission_to_observation_seconds']['minimum'])


if __name__ == '__main__':
    unittest.main()
