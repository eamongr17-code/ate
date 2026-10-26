"""TestFlight "What to Test" for one build: the app PRs merged since the last uploaded build.

  python3 .github/scripts/build_notes.py     (in the Beta workflow; writes the `whats_new` output)

Only major changes get their own line: the lines under a PR's "## What to test" heading, in plain
words for testers. A PR that leaves the section blank, has none, or says "none" is a minor change;
any of those make the notes end with one "Bug fixes and performance improvements." (Eamon, 2026-10-26).
"Since the last build" = since the head commit of the previous successful Beta run on this
branch; only commits that touch the app's paths count, the same paths that trigger Beta.
"""
import json, os, re, subprocess, urllib.request

APP_PATHS = ["App", "AteKit", "ShareExtension", "Config", "Ate.xcodeproj"]
LIMIT = 4000  # App Store Connect's cap on whatsNew
FOOTER = "To report a bug, tap the bug at the top of the You tab."
MINOR = "Bug fixes and performance improvements."
SKIP = {"none", "nothing", "n/a", "na", "-", "minor"}
# Not tester words: a rule (---) ends the section, and PR attribution footers are dropped.
RULE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")
BOILERPLATE = re.compile(r"generated (by|with) \[?claude|claude\.ai/code|^🤖|claude-session:|co-authored-by:", re.I)


def gh(path):
    req = urllib.request.Request("https://api.github.com" + path)
    req.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    req.add_header("Accept", "application/vnd.github+json")
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read().decode())


def previous_build_sha(repo, branch, run_id):
    runs = gh(f"/repos/{repo}/actions/workflows/beta.yml/runs?branch={branch}&status=success&per_page=20")
    for run in runs["workflow_runs"]:
        if str(run["id"]) != str(run_id):
            return run["head_sha"]
    return None


def commits_since(sha):
    rng = [f"{sha}..HEAD"] if sha else ["-15", "HEAD"]
    run = subprocess.run(["git", "log", "--format=%s", *rng, "--", *APP_PATHS], capture_output=True, text=True)
    if run.returncode and sha:  # that commit is gone from history; fall back to recent work
        return commits_since(None)
    out = run.stdout
    return [s for s in out.splitlines() if s.strip()]


def pr_number(subject):
    m = re.search(r"\(#(\d+)\)\s*$", subject)
    return int(m.group(1)) if m else None


def what_to_test(body):
    """The lines under a "What to test" heading, as bullets without their markers.
    None when the PR has no such section or left it blank; [] when it says none or minor."""
    body = re.sub(r"<!--.*?-->", "", body or "", flags=re.S)
    m = re.search(r"^#{1,6}\s*what to test\s*$(.*?)(?=^#{1,6}\s|\Z)", body, re.I | re.M | re.S)
    if not m:
        return None
    raw = m.group(1).splitlines()
    end = next((i for i, l in enumerate(raw) if RULE.match(l)), len(raw))
    lines = [re.sub(r"^\s*(?:[-*•]|\d+[.)])\s*", "", l).strip() for l in raw[:end]]
    lines = [l for l in lines if re.search(r"\w", l) and not BOILERPLATE.search(l)]
    if not lines:  # left blank
        return None
    if lines[0].strip(".").lower() in SKIP:
        return []
    return lines


def compose(build, items, minor=True):
    head = f"New in build {build}:" if build else "New in this build:"
    if not items:
        return f"{MINOR}\n\n{FOOTER}"
    kept, more = [], 0
    for item in items:
        candidate = "\n".join([head, *(f"• {i}" for i in kept + [item])])
        if len(candidate) + len(FOOTER) + 60 > LIMIT:
            more += 1
        else:
            kept.append(item)
    text = "\n".join([head, *(f"• {i}" for i in kept)])
    if more or minor:
        text += f"\n• {MINOR}"
    return f"{text}\n\n{FOOTER}"


def notes(subjects, body_of):
    """(major lines, oldest first; whether any minor change shipped too)."""
    items, minor = [], False
    for s in reversed(subjects):  # oldest first
        n = pr_number(s)
        section = what_to_test(body_of(n)) if n else None
        if section:
            items.extend(section)
        else:
            minor = True
    seen = set()
    return [i for i in items if not (i in seen or seen.add(i))], minor


def pr_body(repo, n):
    try:
        return gh(f"/repos/{repo}/pulls/{n}").get("body") or ""
    except Exception as e:  # a missing body costs that PR its plain words, not the notes
        print(f"::warning::PR #{n}: {e}")
        return ""


def main():
    repo, branch = os.environ["GITHUB_REPOSITORY"], os.environ["BRANCH"]
    sha = previous_build_sha(repo, branch, os.environ["GITHUB_RUN_ID"])
    subjects = commits_since(sha)
    items, minor = notes(subjects, lambda n: pr_body(repo, n))
    text = compose(os.environ.get("BUILD_NUMBER"), items, minor)
    print(f"since {sha or '(no previous build)'}:\n{text}")
    with open(os.environ["GITHUB_OUTPUT"], "a") as f:
        f.write(f"whats_new<<NOTES_EOF\n{text}\nNOTES_EOF\n")


if __name__ == "__main__":
    main()
