"""Offline counterexamples for audit conclusions; no NAS access."""
import json
import unittest

from scripts.emby_audit.audit import (Audit, items, observed_filter, paired_sort,
                                     valid_catalog_page, user_state, person_match,
                                     genre_match, relationship_observation)
from scripts.emby_audit.transport import AuditError, AuditResponse


class AuditSemanticsTests(unittest.TestCase):
    def test_page_contract_rejects_oversize_invalid_ids_duplicates_and_bad_offsets(self):
        valid = {"Items": [{"Id": "one"}], "TotalRecordCount": 2, "StartIndex": 0}
        self.assertTrue(valid_catalog_page(valid, 0))
        for changed in ({"Items": [{"Id": str(i)} for i in range(201)], "TotalRecordCount": 201},
                        {"Items": [{"Id": "one"}, {"Id": "one"}]},
                        {"Items": [{}]}, {"Items": [{"Id": 7}]},
                        {"StartIndex": 1}, {"StartIndex": True}, {"TotalRecordCount": 0}):
            with self.subTest(changed=list(changed)):
                self.assertFalse(valid_catalog_page({**valid, **changed}, 0))
        self.assertFalse(valid_catalog_page({"Items": [{"Id": "two"}], "TotalRecordCount": 3}, 1, expected_total=2))

    def test_missing_or_mistyped_state_is_not_comparable(self):
        self.assertIsNone(user_state({}))
        self.assertIsNone(user_state({"UserData": []}))
        good = {"Played": False, "IsFavorite": True, "PlaybackPositionTicks": 123}
        self.assertEqual(user_state({"UserData": good}), good)
        for changed in ({"Played": 0}, {"IsFavorite": None}, {"PlaybackPositionTicks": True}, {"PlaybackPositionTicks": -1}):
            self.assertIsNone(user_state({"UserData": {**good, **changed}}))

    def test_relationship_counterexample_is_not_missing_data(self):
        self.assertIsNone(person_match({}, "selected"))
        self.assertFalse(person_match({"People": [{"Id": "other"}]}, "selected"))
        self.assertTrue(person_match({"People": [{"Id": "selected"}]}, "selected"))
        self.assertIsNone(person_match({"People": ["malformed"]}, "selected"))
        genre = {"Id": "selected", "Name": "selected name"}
        self.assertIsNone(genre_match({}, genre))
        self.assertFalse(genre_match({"Genres": ["other name"]}, genre))
        self.assertTrue(genre_match({"GenreItems": [{"Id": "selected"}]}, genre))
        self.assertEqual(relationship_observation([True, False, None]), "contradicted")
        self.assertEqual(relationship_observation([True, None]), "missing-data")
        self.assertEqual(relationship_observation([True]), "sample-consistent")

    def test_total_mismatch_stops_before_a_later_page_can_hide_it(self):
        class Client:
            user_id = "private-user"
            def login(self): pass
            def request(self, path, query=None, **kwargs):
                data = {}
                if path.endswith("/Views"):
                    data = {"Items": [{"Id": "library"}]}
                elif path == "Users/private-user/Items" and query.get("ParentId") == "library":
                    offset = query.get("StartIndex", 0)
                    data = {"Items": [{"Id": str(offset), "Type": "Video"}],
                            "TotalRecordCount": 4 if offset == 1 else 3, "StartIndex": offset}
                return AuditResponse(200, data, b"", {})
        report = Audit(Client()).run()
        self.assertFalse(report["libraries"][0]["complete"])
        self.assertEqual(report["libraries"][0]["loaded"], 1)
        pages = [row for row in report["checks"] if row["name"].startswith("library.1.page.")]
        self.assertEqual(len(pages), 1)
        self.assertEqual(pages[0]["observation"], "invalid-pagination")

    def test_malformed_objects_and_missing_user_state_do_not_pass_or_abort(self):
        class Client:
            user_id = "private-user"
            def login(self): pass
            def request(self, path, query=None, **kwargs):
                data = {}
                if path == "System/Info": data = []
                elif path == "Users/private-user": data = {"Policy": []}
                elif path.endswith("/Views"): data = {"Items": [{"Id": "library"}]}
                elif path == "Users/private-user/Items":
                    data = {"Items": [{"Id": "movie", "Name": "private title", "Type": "Movie", "UserData": []}], "TotalRecordCount": 1}
                elif path == "Users/private-user/Items/movie":
                    data = {"Id": "movie", "UserData": [], "People": [None], "Chapters": [None], "MediaSources": 42}
                elif path.endswith("/PlaybackInfo"): data = []
                return AuditResponse(200, data, b"", {})
        report = Audit(Client()).run()
        self.assertEqual(report["stateReadback"], {"sampleCount": 1, "comparableCount": 0, "unchangedCount": 0})
        checks = {row["name"]: row for row in report["checks"]}
        self.assertEqual(checks["system.info"]["observation"], "wrong-shape")
        self.assertEqual(checks["sample.1.playback-info"]["observation"], "wrong-shape")
        self.assertEqual(checks["sample.1.state-readback"]["observation"], "missing-data")

    def test_error_body_cannot_verify_person_membership(self):
        class Client:
            user_id = "private-user"
            def login(self): pass
            def request(self, path, query=None, **kwargs):
                status, data = 200, {}
                if path == "Persons": data = {"Items": [{"Id": "person"}]}
                elif path == "Users/private-user/Items" and query.get("PersonIds"):
                    data = {"Items": [{"Id": "work"}]}
                elif path == "Users/private-user/Items/work":
                    status, data = 500, {"People": [{"Id": "person"}]}
                return AuditResponse(status, data, b"", {})
        report = Audit(Client()).run()
        work = next(row for row in report["checks"] if row["name"] == "people.1.works")
        self.assertEqual(work["metrics"]["detailCheckedItems"], 0)
        self.assertEqual(work["metrics"]["detailMatchedPersonItems"], 0)

    def test_http_success_or_empty_list_does_not_prove_filter_support(self):
        self.assertEqual(observed_filter([], "Played", False), "empty-unproven")
        self.assertEqual(observed_filter([{"Id": "x"}], "Played", False), "missing-data")
        self.assertEqual(observed_filter([{"UserData": {"Played": True}}], "Played", False), "contradicted")
        self.assertEqual(observed_filter([{"UserData": {"Played": False}}], "Played", False), "sample-consistent")
        self.assertEqual(observed_filter([{"UserData": {"Played": 0}}], "Played", False), "missing-data")

    def test_sorting_distinguishes_ignored_parameters_and_unproven_changed_page(self):
        values = [{"Id": str(i)} for i in range(3)]
        self.assertEqual(paired_sort(values, values), "same-order")
        self.assertEqual(paired_sort(values, values[::-1]), "reversed-sample")
        self.assertEqual(paired_sort(values, [{"Id": "other"}, {"Id": "different"}]), "different-order-unproven")
        self.assertEqual(paired_sort(values[:1], values[:1]), "insufficient-sample")

    def test_response_shapes_do_not_confuse_latest_array_with_wrapped_items(self):
        value = {"Id": "private"}
        self.assertEqual(items([value]), [value])
        self.assertEqual(items({"Items": [value], "TotalRecordCount": 1}), [value])
        self.assertEqual(items({"Items": "invalid"}), [])
        self.assertEqual(items([None, "invalid"]), [])

    def test_error_body_and_redirect_location_never_enter_observation_record(self):
        class Client:
            def request(self, *args, **kwargs):
                return AuditResponse(302, {"error": "private-token"}, b"private-title", {"location": "https://secret.example/?api_key=private"})
        audit = Audit(Client())
        audit.read("probe", "Users/private/Items", "/Users/{user}/Items")
        self.assertEqual(audit.rows[0]["observation"], "redirect-refused")
        text = json.dumps(audit.rows)
        for secret in ("private", "secret.example", "api_key", "location"):
            self.assertNotIn(secret, text)

    def test_transport_failure_is_reported_without_private_exception_text(self):
        class Client:
            def request(self, *args, **kwargs):
                raise AuditError("private transport diagnostic")
        audit = Audit(Client())
        audit.read("probe", "System/Info", "/System/Info")
        self.assertEqual(audit.rows[0]["observation"], "transport-error")
        self.assertNotIn("private", json.dumps(audit.rows))

    def test_repeated_page_does_not_claim_complete_catalog_or_loop(self):
        class Client:
            user_id = "private-user"
            def __init__(self):
                self.paths = []
            def login(self):
                pass
            def request(self, path, query=None, method="GET", **kwargs):
                self.paths.append((path, query, method))
                data = {}
                if path.endswith("/Views"):
                    data = {"Items": [{"Id": "private-library"}]}
                elif path == "Users/private-user/Items":
                    # Deliberately ignores StartIndex, search, type and filters.
                    data = {"Items": [{"Id": "private-a", "Name": "secret title a", "Type": "Video"},
                                      {"Id": "private-b", "Name": "secret title b", "Type": "Video"}], "TotalRecordCount": 5}
                return AuditResponse(200, data, b"", {})
        client = Client()
        report = Audit(client).run()
        self.assertEqual(report["libraries"], [{"case": 1, "loaded": 2, "total": 5, "complete": False}])
        self.assertEqual(len([c for c in report["checks"] if c["name"].startswith("library.1.page.")]), 1)
        negative = next(c for c in report["checks"] if c["name"] == "library.1.search-negative")
        self.assertEqual(negative["observation"], "contradicted")
        encoded = json.dumps(report)
        for secret in ("private-user", "private-library", "private-a", "secret title"):
            self.assertNotIn(secret, encoded)
        self.assertEqual(report["limits"]["userStateWrites"], 0)
        self.assertFalse(report["limits"]["playbackStarted"])
        self.assertFalse(any(method != "GET" for _, _, method in client.paths))


if __name__ == "__main__":
    unittest.main()
