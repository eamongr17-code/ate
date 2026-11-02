"""One test notification to one person's phones, straight through APNs (Prod → "test push").

    python .github/scripts/push_test.py <project-ref> <handle>

Env: SUPABASE_ACCESS_TOKEN (reads the person's push tokens through the Management API's SQL endpoint,
a select), APNS_KEY_ID / APNS_PRIVATE_KEY (the GitHub secrets every apply copies into prod).

Proves the key, the topic and the phone's token without anyone tagging anyone: nothing is written to
the database, no notification row is made. What it does NOT prove is the "ate with" trigger and drain
(0059); a real tag does that. Prints one line per phone: ok, or APNs' reason.
"""
import json
import os
import re
import sys
import time
import urllib.request

import httpx
import jwt

TEAM_ID = "9M6K835247"
TOPIC = "com.eamongracias.ate"
HOSTS = {"production": "api.push.apple.com", "sandbox": "api.sandbox.push.apple.com"}


def tokens(ref: str, handle: str) -> list[dict]:
    query = (
        "select t.token, t.apns_env from public.device_push_tokens t "
        "join public.profiles p on p.id = t.user_id "
        f"where lower(p.username) = '{handle}'"
    )
    req = urllib.request.Request(
        f"https://api.supabase.com/v1/projects/{ref}/database/query",
        data=json.dumps({"query": query}).encode(),
        headers={
            "Authorization": f"Bearer {os.environ['SUPABASE_ACCESS_TOKEN']}",
            "Content-Type": "application/json",
            "User-Agent": "ate-push-test",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as res:
        return json.load(res)


def main() -> int:
    ref, raw = sys.argv[1], sys.argv[2]
    handle = raw.strip().lstrip("@").lower()
    if not re.fullmatch(r"[a-z0-9_.]{1,30}", handle):
        print(f"Not a handle: {raw!r}")
        return 1
    key_id, key = os.environ.get("APNS_KEY_ID", ""), os.environ.get("APNS_PRIVATE_KEY", "")
    if not key_id or not key:
        print("APNS_KEY_ID / APNS_PRIVATE_KEY are not set.")
        return 1
    phones = tokens(ref, handle)
    if not phones:
        print(f"@{handle} has no phone with notifications allowed.")
        return 1
    bearer = jwt.encode({"iss": TEAM_ID, "iat": int(time.time())}, key.replace("\\n", "\n"),
                        algorithm="ES256", headers={"kid": key_id})
    body = {"aps": {"alert": {"title": "Test from Ate", "body": "Notifications reach this phone."},
                    "sound": "default"}}
    failed = 0
    with httpx.Client(http2=True, timeout=15) as client:
        for phone in phones:
            host = HOSTS.get(phone["apns_env"])
            if host is None:
                continue
            res = client.post(
                f"https://{host}/3/device/{phone['token']}",
                headers={"authorization": f"bearer {bearer}", "apns-topic": TOPIC,
                         "apns-push-type": "alert", "apns-priority": "10"},
                json=body,
            )
            tail = phone["token"][-6:]
            if res.status_code == 200:
                print(f"…{tail} ({phone['apns_env']}): ok")
            else:
                failed += 1
                reason = (res.json() or {}).get("reason", "") if res.content else ""
                print(f"…{tail} ({phone['apns_env']}): HTTP {res.status_code} {reason}")
    return 0 if failed < len(phones) else 1


if __name__ == "__main__":
    sys.exit(main())
