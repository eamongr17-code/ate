"""build_notes without GitHub: which PR text becomes a tester line.

  python3 .github/scripts/build_notes_test.py
"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(__file__))
import build_notes as bn  # noqa: E402


class WhatToTest(unittest.TestCase):
    def test_section_lines_become_items(self):
        body = "## Summary\nTech words.\n\n## What to test\n- Photos open from the Feed\n* Share opens on Story\n\n## Notes\nx"
        self.assertEqual(bn.what_to_test(body), ["Photos open from the Feed", "Share opens on Story"])

    def test_none_skips_the_pr(self):
        self.assertEqual(bn.what_to_test("### What to test\nNone.\n"), [])

    def test_no_section(self):
        self.assertIsNone(bn.what_to_test("## Summary\nhi"))
        self.assertIsNone(bn.what_to_test(None))

    def test_blank_template_falls_back_to_the_title(self):
        template = open(os.path.join(os.path.dirname(__file__), "..", "pull_request_template.md")).read()
        self.assertIsNone(bn.what_to_test(template))
        self.assertEqual(bn.what_to_test(template + "- Photos open smoothly\n"), ["Photos open smoothly"])


class Notes(unittest.TestCase):
    def test_oldest_first_section_over_title_and_dedup(self):
        subjects = [  # git log order: newest first
            "Snapshot tests (#283)",
            "Composer: one scrolling page (#273)",
            "Photo flight fix (#280)",
            "Untagged commit",
        ]
        bodies = {283: "## What to test\nnone", 273: "## What to test\n- Long reviews scroll with the photos",
                  280: "", }
        items = bn.notes(subjects, lambda n: bodies[n])
        self.assertEqual(items, ["Untagged commit", "Photo flight fix", "Long reviews scroll with the photos"])

    def test_compose(self):
        text = bn.compose("301", ["A", "B"])
        self.assertEqual(text, "New in build 301:\n• A\n• B\n\n" + bn.FOOTER)
        self.assertTrue(bn.compose("301", []).startswith("Small fixes"))

    def test_compose_stays_under_the_cap(self):
        text = bn.compose("1", ["x" * 300] * 30)
        self.assertLessEqual(len(text), bn.LIMIT)
        self.assertIn("more small changes", text)


if __name__ == "__main__":
    unittest.main()
