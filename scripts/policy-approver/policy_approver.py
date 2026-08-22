#!/usr/bin/env python3
"""Policy approver — auto-approve verified incident-remediation PRs (Day 3 advanced lab).

Runs on the monitoring host. Approves + merges a prod disk-grow PR ONLY when
the alert fingerprint it references is actually firing in Grafana right now.
The PR text is a pointer (a lookup key), not evidence — every value the policy
consumes (alarm name, instance) is taken from the Grafana response, never from
the PR body. A forged fingerprint finds nothing; someone else's fingerprint
fails the policy/env checks.

Repo gates (CODEOWNERS, rulesets, auto-merge.yml) stay untouched: this service
automates the owner's own review click with the owner's fine-grained PAT, so a
normal (non-incident) prod PR still waits for a human.

Two modes:
  (default)        webhook server for the systemd variant — validates HMAC itself
  --check-pr <n>   one-shot verdict on a single PR, for an external receiver
                   that already authenticated the webhook (e.g. the Hermes
                   gateway variant in ./hermes/) — no WEBHOOK_SECRET needed

Pipeline per request (course material, "심화 실습" section):
  HMAC verify -> event/action/bot/base filter -> parse alarm_id (fingerprint)
  -> Grafana firing lookup by fingerprint -> policy map on the RESPONSE's
  alarm name + prod-instance check -> single-file diff check (grow-only, cap)
  -> wait for guard -> approve review + evidence comment + label + squash merge

Stdlib only (Python 3.9+). Config via environment — see policy-approver.env.example.
"""

import hashlib
import hmac
import json
import os
import queue
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------- configuration

WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")
GITHUB_TOKEN = os.environ.get("GITHUB_TOKEN", "")
GITHUB_REPO = os.environ.get("GITHUB_REPO", "")  # "owner/repo"
GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://localhost:3000")
GRAFANA_TOKEN = os.environ.get("GRAFANA_TOKEN", "")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8646"))
# Env-consistency hint: a base=main PR must be justified by a *prod* instance
# alarm. Instance Name tags contain the environment (e.g. ops-agent-prod-app-0).
PROD_NAME_HINT = os.environ.get("PROD_NAME_HINT", "prod")
GUARD_POLL_SECONDS = 15
GUARD_POLL_MAX = 40  # 40 x 15s = 10 min

APPROVED_LABEL = "incident-auto-approved"

# The policy itself: which alarm justifies which change. Keyed by alarm name
# (the "[monitoring] " prefix is stripped on both sides before comparing).
# Severity is deliberately NOT part of the policy — the disk alarm is `warning`.
POLICY = {
    "instance /data disk high": {
        "file": "2-2-prod/disk.auto.tfvars",
        "var": "data_volume_size_gb",
        "max": 100,  # must match the variables.tf validation (1..100 GiB)
    },
}


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%S%z") + " " + msg, flush=True)


# ---------------------------------------------------------------- http clients


def _request(url, token, method="GET", body=None, accept="application/json"):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", accept)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else {}


def gh(path, method="GET", body=None):
    return _request(
        "https://api.github.com/repos/" + GITHUB_REPO + path,
        GITHUB_TOKEN,
        method,
        body,
        accept="application/vnd.github+json",
    )


def grafana_firing_alerts():
    """Currently firing alerts from Grafana's built-in alertmanager."""
    return _request(
        GRAFANA_URL + "/api/alertmanager/grafana/api/v2/alerts?active=true",
        GRAFANA_TOKEN,
    )


# ---------------------------------------------------------------- pure checks


def verify_signature(secret, body, signature_header):
    if not signature_header or not signature_header.startswith("sha256="):
        return False
    expected = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest("sha256=" + expected, signature_header)


def strip_alarm_prefix(name):
    return re.sub(r"^\[[^\]]+\]\s*", "", name or "").strip()


def parse_alarm_id(pr_body):
    """Extract alarm_id=<fingerprint> from the PR body's request line.

    The agent skill is instructed to copy the "알람 ID" value from the Slack
    alarm notification into the tfvars-PR reason, e.g.
      alarm_id=a1b2c3d4e5f60718
    The Slack template renders it in backticks, so tolerate them. Returns the
    fingerprint (lowercased) or None.
    """
    m = re.search(r"alarm_id=`?([0-9a-fA-F]{8,64})`?", pr_body or "")
    return m.group(1).lower() if m else None


def parse_var(content, var):
    m = re.search(r"^\s*%s\s*=\s*(\d+)\s*$" % re.escape(var), content, re.M)
    return int(m.group(1)) if m else None


def content_without_var(content, var):
    """File content minus the policy variable's line — must be identical between
    base and head, so the PR changes nothing but that one value."""
    return "\n".join(
        l
        for l in (content or "").splitlines()
        if not re.match(r"^\s*%s\s*=" % re.escape(var), l)
    ).strip()


# ---------------------------------------------------------------- pipeline


def find_firing(fingerprint):
    """Return the firing alert with this fingerprint, or None.

    The fingerprint is the alertmanager label-set hash — it names one rule on
    one instance in a single value, so the lookup needs no name matching. What
    the alert actually is (alertname, instance) is read from the response by
    the caller; the PR body contributed nothing but the key."""
    for alert in grafana_firing_alerts():
        if (alert.get("fingerprint") or "").lower() != fingerprint:
            continue
        if alert.get("status", {}).get("state") not in ("active", None):
            continue
        return alert
    return None


def fetch_file_at(ref, path):
    data = gh("/contents/" + path + "?ref=" + ref, method="GET")
    if data.get("encoding") == "base64":
        import base64

        return base64.b64decode(data["content"]).decode()
    return data.get("content", "")


def wait_for_guard(head_sha):
    """The ruleset requires the `guard` check; right after PR open it is still
    running. Poll until it concludes."""
    for _ in range(GUARD_POLL_MAX):
        runs = gh("/commits/" + head_sha + "/check-runs").get("check_runs", [])
        guard = [r for r in runs if r.get("name") == "guard"]
        if guard and guard[0].get("status") == "completed":
            return guard[0].get("conclusion") == "success"
        time.sleep(GUARD_POLL_SECONDS)
    return False


def process(pr):
    number = pr["number"]
    head_sha = pr["head"]["sha"]
    tag = "PR #%d (%s)" % (number, head_sha[:7])

    # -- filter: bot author, base=main, exactly the policy file
    author = pr.get("user", {})
    if author.get("type") != "Bot" and not author.get("login", "").endswith("[bot]"):
        return log("skip %s: author %s is not a bot" % (tag, author.get("login")))
    if pr.get("base", {}).get("ref") != "main":
        return log("skip %s: base is not main" % tag)

    fingerprint = parse_alarm_id(pr.get("body"))
    if not fingerprint:
        return log("skip %s: no alarm_id in body" % tag)

    # -- evidence first: the referenced alert must be firing right now. Every
    #    policy input below (alarm name, instance) comes from this response.
    alert = find_firing(fingerprint)
    if not alert:
        return log("skip %s: alarm_id %s not firing" % (tag, fingerprint))
    labels = alert.get("labels", {})
    alarm = strip_alarm_prefix(labels.get("alertname"))
    instance = labels.get("name") or labels.get("instance", "")
    policy = POLICY.get(alarm)
    if not policy:
        return log("skip %s: alarm %r not in policy" % (tag, alarm))
    if PROD_NAME_HINT not in instance.lower():
        # a base=main PR can't be justified by a dev alarm
        return log("skip %s: instance %r is not prod" % (tag, instance))

    files = gh("/pulls/%d/files?per_page=10" % number)
    if len(files) != 1 or files[0].get("filename") != policy["file"]:
        return log(
            "skip %s: files %r != [%s]"
            % (tag, [f.get("filename") for f in files], policy["file"])
        )

    # -- diff check: single value, grow-only, within cap, nothing else changed
    base_content = fetch_file_at(pr["base"]["sha"], policy["file"])
    head_content = fetch_file_at(head_sha, policy["file"])
    old = parse_var(base_content, policy["var"])
    new = parse_var(head_content, policy["var"])
    if old is None or new is None:
        return log("skip %s: cannot parse %s" % (tag, policy["var"]))
    if new <= old:
        return log("skip %s: not grow-only (%s -> %s)" % (tag, old, new))
    if new > policy["max"]:
        return log("skip %s: %s exceeds cap %s" % (tag, new, policy["max"]))
    if content_without_var(base_content, policy["var"]) != content_without_var(
        head_content, policy["var"]
    ):
        return log("skip %s: file changes beyond %s" % (tag, policy["var"]))

    # -- the plan gate must agree before any approval goes out
    log(
        "%s: verified (%s %s->%s, alarm firing since %s) — waiting for guard"
        % (tag, policy["var"], old, new, alert.get("startsAt"))
    )
    if not wait_for_guard(head_sha):
        return log("skip %s: guard did not succeed" % tag)

    # -- approve + evidence + label + merge (idempotent enough for re-delivery:
    #    a second run on a merged PR fails at the merge step harmlessly)
    evidence = (
        "정책 승인자 자동 승인.\n\n"
        "- 알람: `%s` (instance `%s`, fingerprint `%s`) — firing 확인 %s, "
        "startsAt %s\n"
        "  (알람 이름·인스턴스는 PR 본문이 아니라 Grafana 조회 응답 값)\n"
        "- 변경: `%s` %s → %s GiB (grow-only, 상한 %s 이내)\n"
        "- guard: success\n"
        % (
            alarm,
            instance,
            fingerprint,
            time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            alert.get("startsAt"),
            policy["var"],
            old,
            new,
            policy["max"],
        )
    )
    gh("/pulls/%d/reviews" % number, "POST", {"event": "APPROVE", "body": evidence})
    gh("/issues/%d/labels" % number, "POST", {"labels": [APPROVED_LABEL]})
    gh("/pulls/%d/merge" % number, "PUT", {"merge_method": "squash", "sha": head_sha})
    log("%s: approved and merged" % tag)


# ---------------------------------------------------------------- webhook server

WORK = queue.Queue()
SEEN = set()  # (pr_number, head_sha) — webhook re-deliveries and duplicates


def worker():
    while True:
        pr = WORK.get()
        try:
            process(pr)
        except urllib.error.HTTPError as e:
            log(
                "error PR #%s: HTTP %s %s — %s"
                % (pr.get("number"), e.code, e.reason, e.read()[:300])
            )
        except Exception as e:
            log("error PR #%s: %r" % (pr.get("number"), e))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # route http.server's own logging through ours
        pass

    def _respond(self, code, text=""):
        self.send_response(code)
        self.end_headers()
        self.wfile.write(text.encode())

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        # Nothing enters the pipeline before the signature checks out.
        if not verify_signature(
            WEBHOOK_SECRET, body, self.headers.get("X-Hub-Signature-256")
        ):
            log("reject: bad signature from %s" % self.client_address[0])
            return self._respond(401)

        event = self.headers.get("X-GitHub-Event", "")
        if event == "ping":
            return self._respond(200, "pong")
        if event != "pull_request":
            return self._respond(204)

        payload = json.loads(body)
        if payload.get("action") not in ("opened", "synchronize"):
            return self._respond(204)
        pr = payload.get("pull_request", {})
        key = (pr.get("number"), pr.get("head", {}).get("sha"))
        if key in SEEN:
            return self._respond(202, "duplicate")
        SEEN.add(key)
        WORK.put(pr)  # guard wait takes minutes — never block the webhook reply
        self._respond(202, "queued")


def main():
    one_shot = None
    if len(sys.argv) == 3 and sys.argv[1] == "--check-pr":
        one_shot = int(sys.argv[2])
    elif len(sys.argv) != 1:
        sys.exit("usage: policy_approver.py [--check-pr <number>]")

    required = [
        ("GITHUB_TOKEN", GITHUB_TOKEN),
        ("GITHUB_REPO", GITHUB_REPO),
        ("GRAFANA_TOKEN", GRAFANA_TOKEN),
    ]
    if one_shot is None:
        # only the built-in server authenticates webhooks itself; in one-shot
        # mode the external receiver (Hermes gateway) already validated HMAC
        required.append(("WEBHOOK_SECRET", WEBHOOK_SECRET))
    missing = [k for k, v in required if not v]
    if missing:
        sys.exit("missing config: " + ", ".join(missing))

    if one_shot is not None:
        try:
            process(gh("/pulls/%d" % one_shot))
        except urllib.error.HTTPError as e:
            sys.exit(
                "error PR #%d: HTTP %s %s — %s"
                % (one_shot, e.code, e.reason, e.read()[:300])
            )
        return

    threading.Thread(target=worker, daemon=True).start()
    log("policy-approver listening on :%d for %s" % (LISTEN_PORT, GITHUB_REPO))
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
