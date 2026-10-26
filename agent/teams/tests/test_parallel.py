"""parallel.py: the summary names the opt-in test groups the environment skipped."""

import unittest

from tests import parallel

DAEMONS = [
    "tests.test_team.StopAgentTest.test_client_stop_leaves_real_daemons_started_by_a_client_query",
    "tests.test_team.PairTest.test_two_allocations_use_isolated_real_daemons",
    "tests.test_team.PairTest.test_stop_stops_real_daemons_before_cleanup_deletes_the_projects",
]
CODEX = [
    "tests.test_team.PairTest.test_codex_started_in_the_allocation_ignores_the_clone_configuration"
]
OTHER = ["tests.test_read.SectionTest.test_the_slug_matches_the_docs_checker_rule"]


class SkippedOptInsTest(unittest.TestCase):
    def test_each_unset_opt_in_is_named_once_with_its_count_and_requirement(self) -> None:
        lines = parallel.skipped_opt_ins(DAEMONS + CODEX + OTHER, {})
        assert lines == [
            "skipped opt-in: real-daemon tests (3): set TIPS_TEST_REAL_DEXTER and "
            "DEXTER_ELIXIR_LIB_ROOT; required for non-Markdown agent/teams changes "
            "(agent/teams/development.md#required-checks)",
            "skipped opt-in: installed-Codex tests (1): set TIPS_TEST_REAL_CODEX; required for "
            "Codex launch argument changes (agent/teams/development.md#required-checks)",
        ]

    def test_a_set_opt_in_and_a_selection_without_its_tests_say_nothing(self) -> None:
        both = {
            "TIPS_TEST_REAL_DEXTER": "/dexter",
            "DEXTER_ELIXIR_LIB_ROOT": "/lib",
            "TIPS_TEST_REAL_CODEX": "1",
        }
        assert parallel.skipped_opt_ins(DAEMONS + CODEX, both) == []
        assert parallel.skipped_opt_ins(OTHER, {}) == []
        # -k narrowed the run to one daemon case: the count is the selection's, not three.
        assert parallel.skipped_opt_ins(DAEMONS[:1], {}) == [
            "skipped opt-in: real-daemon tests (1): set TIPS_TEST_REAL_DEXTER and "
            "DEXTER_ELIXIR_LIB_ROOT; required for non-Markdown agent/teams changes "
            "(agent/teams/development.md#required-checks)"
        ]

    def test_the_markers_match_the_suite_s_opt_in_tests(self) -> None:
        ids = parallel.test_ids([])
        for marker, _variables, _name, _required in parallel.OPT_INS:
            assert any(marker in test_id for test_id in ids), marker


if __name__ == "__main__":
    unittest.main()
