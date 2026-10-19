import copy
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location('repair', pathlib.Path(__file__).with_name('repair-terminal-only-history.py'))
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)

class HistoryRepairTests(unittest.TestCase):
    def fixture(self):
        bad = {'endpoint': 'deepseek:https://api.deepseek.com', 'model': 'deepseek-v4-pro', 'side': 'white', 'advice': 'Урок трёх нелегальных ответов'}
        other = {'endpoint': 'other', 'model': 'other', 'side': 'black', 'advice': 'Keep this'}
        return {'series': {'roundID': repair.ROUND, 'running': False, 'score': copy.deepcopy(repair.OLD)},
                'white': {'model': 'deepseek-v4-pro'}, 'black': {'model': 'Leela Chess Zero'},
                'game': {'referee': {'position': repair.FEN, 'accepted': ['preserved']}, 'requestCount': 21},
                'gameMemory': {'entries': [bad, other]}}

    def test_scoped_repair_preserves_position_selection_and_unrelated_memory(self):
        original = self.fixture(); pristine = copy.deepcopy(original)
        updated, quarantined = repair.correction(original, repair.OLD)
        self.assertEqual(original, pristine)
        self.assertEqual(updated['series']['score'], repair.NEW)
        self.assertEqual(updated['game'], original['game'])
        self.assertEqual(updated['black'], original['black'])
        self.assertEqual(updated['gameMemory']['entries'], [original['gameMemory']['entries'][1]])
        self.assertEqual(len(quarantined), 1)

    def test_changed_identity_or_unknown_totals_are_never_rewritten(self):
        for field, value in [('roundID', 'other'), ('running', True), ('score', repair.NEW)]:
            state = self.fixture(); state['series'][field] = value
            with self.assertRaises(ValueError): repair.correction(state, repair.OLD)
        with self.assertRaises(ValueError): repair.correction(self.fixture(), {'games': 3, 'whiteHalfPoints': 2, 'blackHalfPoints': 4})

    def test_repeat_cannot_subtract_points_again(self):
        updated, _ = repair.correction(self.fixture(), repair.OLD)
        with self.assertRaises(ValueError): repair.correction(updated, repair.NEW)

    def test_valid_advice_for_same_model_is_not_removed(self):
        state = self.fixture(); state['gameMemory']['entries'][0]['advice'] = 'Verified lesson from a real mate'
        updated, quarantined = repair.correction(state, repair.OLD)
        self.assertEqual(updated['gameMemory'], state['gameMemory'])
        self.assertEqual(quarantined, [])

if __name__ == '__main__': unittest.main()
