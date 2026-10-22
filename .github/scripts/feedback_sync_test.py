"""feedback_sync against fakes: what an app report becomes, and when a resend joins an open issue.

  python3 .github/scripts/feedback_sync_test.py
"""
import os, sys, unittest

sys.path.insert(0, os.path.dirname(__file__))
import feedback_sync as fs  # noqa: E402


class FakeDB:
    def __init__(self, rows, prior=None):
        self.rows, self.prior, self.patches, self.deleted = rows, prior or [], [], []

    def rest(self, method, path, body=None, prefer=None):
        if method == "GET" and path.startswith("feedback?status=eq.new"):
            return self.rows
        if method == "GET" and path.startswith("profiles?"):
            return [{"id": "u1", "username": "paris"}]
        if method == "GET" and path.startswith("feedback?fingerprint="):
            return self.prior
        if method == "PATCH":
            self.patches.append((path, body))
            return {}
        raise AssertionError(f"unexpected {method} {path}")

    def screenshot(self, path):
        return b"jpeg:" + path.encode()

    def delete_screenshots(self, paths):
        self.deleted += paths


class FakeRepo:
    def __init__(self, open_numbers=()):
        self.files, self.issues, self.comments, self.open_numbers = {}, [], [], set(open_numbers)

    def put_file(self, path, content, message):
        self.files[path] = content
        return f"https://github.com/o/r/blob/HEAD/{path}?raw=true"

    def open_issue(self, title, body, labels):
        self.issues.append((title, body, labels))
        return 40 + len(self.issues)

    def is_open(self, number):
        return number in self.open_numbers

    def comment(self, number, body):
        self.comments.append((number, body))


ROW = {"id": "f1", "user_id": "u1", "body": "The place sheet froze\nwhen I tapped back",
       "screenshots": ["u1/f1/1.jpg"], "build": "162", "device": "iPhone18,1", "os_version": "26.1",
       "screens": ["journal", "place"], "fingerprint": "abc", "created_at": "2026-10-22T09:15:00+00:00"}


class SyncApp(unittest.TestCase):
    def test_a_new_report_opens_an_issue_with_its_screenshots_then_leaves_storage(self):
        db, repo = FakeDB([dict(ROW)]), FakeRepo()
        self.assertEqual(fs.sync_app(db, repo, []), 1)
        title, body, labels = repo.issues[0]
        self.assertEqual(title, "The place sheet froze")
        self.assertIn("> The place sheet froze\n> when I tapped back", body)
        self.assertIn("| From | @paris |", body)
        self.assertIn("journal → place", body)
        self.assertIn("![screenshot 1](https://github.com/o/r/blob/HEAD/screenshots/f1/1.jpg?raw=true)", body)
        self.assertEqual(labels, ["triage:new", "source:app"])
        self.assertEqual(repo.files["screenshots/f1/1.jpg"], b"jpeg:u1/f1/1.jpg")
        path, patch = db.patches[0]
        self.assertEqual(path, "feedback?id=eq.f1")
        self.assertEqual((patch["status"], patch["issue_number"], patch["screenshots"]), ("filed", 41, ["screenshots/f1/1.jpg"]))
        self.assertEqual(db.deleted, ["u1/f1/1.jpg"])

    def test_a_resend_comments_on_the_open_issue(self):
        db, repo = FakeDB([dict(ROW)], prior=[{"issue_number": 7}]), FakeRepo(open_numbers={7})
        fs.sync_app(db, repo, [])
        self.assertEqual(repo.issues, [])
        self.assertEqual(repo.comments[0][0], 7)
        self.assertEqual(db.patches[0][1]["issue_number"], 7)

    def test_a_resend_after_the_issue_closed_opens_a_new_one(self):
        db, repo = FakeDB([dict(ROW)], prior=[{"issue_number": 7}]), FakeRepo(open_numbers=set())
        fs.sync_app(db, repo, ["staging"])
        self.assertEqual(len(repo.issues), 1)
        self.assertEqual(repo.issues[0][2], ["triage:new", "source:app", "staging"])

    def test_a_failure_leaves_the_report_new_for_the_next_run(self):
        class Broken(FakeRepo):
            def put_file(self, *a):
                raise fs.HTTPFail(502, "bad gateway")
        db = FakeDB([dict(ROW)])
        self.assertEqual(fs.sync_app(db, Broken(), []), 0)
        self.assertEqual(db.patches, [])
        self.assertEqual(db.deleted, [])


class Titles(unittest.TestCase):
    def test_the_first_line_cut_to_72(self):
        self.assertEqual(fs.title_of("\n\n  hi there \nmore"), "hi there")
        self.assertEqual(len(fs.title_of("x" * 200)), 70)
        self.assertEqual(fs.title_of("   "), "Feedback")


if __name__ == "__main__":
    unittest.main()
