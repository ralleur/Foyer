#!/usr/bin/env python3
"""Ledger rules of the nightly check: a title is checked once, again only when its file changed or it failed (max. three tries)."""
import os, sys, unittest
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import nightly


def item(i, kind="Movie", size=1, series=None, season=1, created="2026-01-01"):
    return {"Id": i, "Type": kind, "Name": i, "RunTimeTicks": 60_000_000_000, "DateCreated": created,
            "SeriesId": series, "ParentIndexNumber": season, "MediaSources": [{"Path": f"/m/{i}.mkv", "Size": size}]}


class LedgerRules(unittest.TestCase):
    def test_new_mode_never_repeats_a_checked_title(self):
        items = [item("a"), item("b"), item("c"), item("d")]
        ledger = {}
        for it in items[:2]:
            nightly.record(ledger, {"id": it["Id"], "result": "ok", "route": "x"}, it, "2026-09-27")
        nightly.record(ledger, {"id": "c", "result": "warn"}, items[2], "2026-09-27")
        chosen = [it["Id"] for it in nightly.select_items(items, ledger, "new", 0)]
        self.assertEqual(chosen, ["d"], "ok and warn titles are not checked again")

    def test_changed_file_is_checked_again(self):
        it = item("a", size=100)
        ledger = {}
        nightly.record(ledger, {"id": "a", "result": "ok"}, it, "2026-09-27")
        self.assertEqual(nightly.select_items([it], ledger, "new", 0), [])
        replaced = item("a", size=200)
        self.assertEqual([x["Id"] for x in nightly.select_items([replaced], ledger, "new", 0)], ["a"])

    def test_metadata_refresh_does_not_trigger_a_recheck(self):
        it = item("a")
        ledger = {}
        nightly.record(ledger, {"id": "a", "result": "ok"}, it, "2026-09-27")
        it["Etag"] = "different-after-a-library-scan"
        it["Name"] = "renamed"
        self.assertEqual(nightly.select_items([it], ledger, "new", 0), [])

    def test_failures_are_retried_three_times(self):
        it = item("a")
        ledger = {}
        for attempt in range(3):
            self.assertEqual([x["Id"] for x in nightly.select_items([it], ledger, "new", 0)], ["a"], f"attempt {attempt + 1}")
            nightly.record(ledger, {"id": "a", "result": "fail"}, it, "2026-09-27")
        self.assertEqual(nightly.select_items([it], ledger, "new", 0), [], "given up after three failures")
        nightly.record(ledger, {"id": "a", "result": "ok"}, it, "2026-09-28")
        self.assertEqual(ledger["a"]["failures"], 0, "a success resets the counter")

    def test_order_movies_then_one_episode_per_season(self):
        items = [item("e1", "Episode", series="s", season=1), item("e2", "Episode", series="s", season=1), item("m1"),
                 item("e3", "Episode", series="s", season=2), item("e4", "Episode", series="t", season=1)]
        self.assertEqual([x["Id"] for x in nightly.ordered(items)], ["m1", "e1", "e3", "e4", "e2"])

    def test_no_duplicates_in_a_queue(self):
        items = [item("a"), item("a"), item("b")]
        chosen = nightly.select_items(items, {}, "new", 0)
        self.assertEqual([x["Id"] for x in chosen], ["a", "b"], "an id listed twice by the server is queued once")

    def test_budget(self):
        self.assertEqual(nightly.budget_for(item("m"), 150), 150)
        self.assertEqual(nightly.budget_for(item("e", "Episode"), 150), 60)


if __name__ == "__main__":
    unittest.main()
