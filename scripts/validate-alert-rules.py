#!/usr/bin/env python3
"""CTC-5029: the Grafana alert rules in provisioning/alerting/ are the live set, and none reads a frozen store.

Static mode (no network, the default) fails when:
  - a rule names a datasource uid this stack does not provision;
  - any alerting or datasource file names the frozen `home` ClickHouse (data stops 2026-09-19 11:48Z);
  - a ClickHouse datasource in grafana-datasources.yml points anywhere but the live box;
  - two rules share a uid, or the policy tree routes to a contact point that does not exist;
  - a per-host liveness rule (uid prefix `catalyst_host_`) maps no data to anything but NoData
    (CTC-5149: the disk rule read a metric with 0 series for 30 days and reported OK throughout).
Planted negative controls prove the unknown-uid gate and the frozen-store gate each reject a rule on their own.

Live mode (`--live http://127.0.0.1:13001`, run on `home`) also fails when:
  - Grafana's provisioned rule set differs from the files (missing, extra, or changed rule, or a changed group
    interval or folder), including a rule a file lists under deleteRules that Grafana still carries;
  - a contact point or the policy root does not read back as provisioned (webhook unset, header missing);
  - a datasource a rule reads resolves, inside the otel-grafana container, to a frozen host;
  - a ClickHouse datasource's newest otel_logs row is older than one hour;
  - an alert rule reads only Prometheus metrics that have had no series for the last 24h
    (CTC-5149: a rule whose metric is gone cannot fire and must be named, not silently green).
Live mode only reads: GETs on the provisioning and datasource APIs, and SELECT/count queries through /api/ds/query.
"""
import argparse
import copy
import json
import re
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
ALERTING_DIR = ROOT / "provisioning" / "alerting"
DATASOURCES_FILE = ROOT / "grafana-datasources.yml"

# Provisioned by catalyst-otel-private (private/grafana/datasources-private.yml), so not visible in this repo.
# Its host is checked in live mode.
PRIVATE_DATASOURCE_UIDS = {"clickhouse-trial"}
EXPRESSION_UIDS = {"__expr__", "-100"}

# The frozen store: home's own ClickHouse. 100.65.193.30 is home's tailnet address, 10.87.0.5 its Mesh address, and
# `clickstack-clickhouse` the container name Grafana would reach on home's Docker network.
FROZEN_MARKERS = ["100.65.193.30", "10.87.0.5", "home.rozich.com:18123", "clickstack-clickhouse"]
FROZEN_IPS = {"100.65.193.30", "10.87.0.5", "127.0.0.1"}
LIVE_CLICKHOUSE_HOST = "clickhouse.int.catalystcloud.dev"
GRAFANA_CONTAINER = "otel-grafana"
FRESHNESS_LIMIT_S = 3600

# CTC-5149. Rules whose uid carries this prefix watch a per-host liveness gauge (disk, memory) that
# exists only while the host keeps reporting, so "no data" IS the failure the rule exists to catch
# and must never be mapped to OK. The dead disk rule sat exactly here for 30 days.
HOST_LIVENESS_UID_PREFIX = "catalyst_host_"
# How far back the live mode series gate looks for at least one sample of each metric a rule reads.
# 24h tolerates a daily-cron producer and a short scrape gap; the bug this catches (30 days at 0
# series) is three orders of magnitude past it.
PROMETHEUS_SERIES_LOOKBACK = "24h"

# PromQL words that can never be a metric name: aggregations, operators, set/label modifiers, and
# every function the expression language ships. Anything else the token regex finds and that does
# not sit in a call position or a label-name position is treated as a metric the rule reads.
PROMQL_NON_METRIC_TOKENS = frozenset(
    """abs absent absent_over_time acos acosh asin asinh atan atanh atan2 avg avg_over_time
    and bool bottomk by ceil changes clamp clamp_max clamp_min count count_over_time count_values
    day_of_month day_of_week day_of_year days_in_month default delta double_exponential_smoothing
    exp floor group group_left group_right histogram_avg histogram_count histogram_fraction
    histogram_quantile histogram_stddev histogram_stdvar holt_winters hour idelta ignoring
    increase irate label_join label_replace last_over_time ln log10 log2 mad_over_time max
    max_over_time min min_over_time minute month offset on or predict_linear present_over_time
    quantile quantile_over_time rad rate resets round scalar sgn sin sinh sort sort_by_label
    sort_by_label_desc sort_desc sqrt start stddev stddev_over_time stdvar stdvar_over_time
    sum sum_over_time tan tanh time timestamp topk unless vector without year""".split()
)
PROMQL_TOKEN = re.compile(r"[a-zA-Z_:][a-zA-Z0-9_:]*")


def promql_metric_names(expr):
    """The metric identifiers a PromQL expression reads, deduped and sorted. Conservative by design:
    a word wrongly kept only adds one cheap count query, a word wrongly dropped could hide a dead
    metric — so the denylist is exact functions/keywords only, label lists after by/on/ignoring/
    without/group_* are stripped wholesale, strings and Grafana template vars are removed first, and
    anything in a call position or before a label matcher is not a metric."""
    text = re.sub(r'"(?:[^"\\]|\\.)*"', '""', str(expr))
    text = re.sub(r"'(?:[^'\\]|\\.)*'", "''", text)
    text = re.sub(r"\$\{\w+[^}]*\}", "", text)
    text = re.sub(r"\$\w+", "", text)
    text = re.sub(r"\[[^\]]*\]", "[]", text)
    text = re.sub(r"\boffset\s+[\d.]+[smhdwy]+\b", "offset", text)
    text = re.sub(r"\b(by|without|on|ignoring|group_left|group_right)\s*\([^)]*\)", r"\1()", text)
    names = set()
    for match in PROMQL_TOKEN.finditer(text):
        token = match.group(0)
        if token in PROMQL_NON_METRIC_TOKENS:
            continue
        after = text[match.end():].lstrip()
        if after.startswith("(") or re.match(r"(=~|!~|!=|=)", after):
            continue
        names.add(token)
    return sorted(names)


def host_liveness_nodata_problems(rule):
    """A per-host liveness rule must map no data to NoData — never OK (CTC-5149 scenario 3)."""
    if not str(rule.get("uid", "")).startswith(HOST_LIVENESS_UID_PREFIX):
        return []
    if rule.get("noDataState") != "NoData":
        return [f"noDataState is {rule.get('noDataState')!r}, not 'NoData': a per-host liveness rule"
                " whose metric disappears must say no data, never OK"]
    return []


def rule_series_problems(rule, count_fn):
    """A rule that reads Prometheus metrics fails when EVERY metric it names has no series: the
    rule cannot fire and has been silently green exactly as long as the metric has been gone.
    count_fn returns the series count for a metric name, or None when the query itself failed —
    a count the validator could not take is never read as a pass."""
    metrics = set()
    for query in rule.get("data") or []:
        if query.get("datasourceUid") != "prometheus":
            continue
        metrics.update(promql_metric_names((query.get("model") or {}).get("expr") or ""))
    if not metrics:
        return []
    dead = sorted(m for m in metrics if not count_fn(m))
    if len(dead) < len(metrics):
        return []
    return [f"reads Prometheus metric(s) {dead} with no series in the last {PROMETHEUS_SERIES_LOOKBACK};"
            " the rule can never fire"]

failures = []


def ok(msg):
    print(f"OK: {msg}")


def fail(msg):
    print(f"FAIL: {msg}")
    failures.append(msg)


def load_yaml_files(directory):
    docs = {}
    for path in sorted(directory.glob("*.y*ml")):
        docs[path.name] = yaml.safe_load(path.read_text()) or {}
    return docs


def deleted_uids_from(docs):
    return {d["uid"]: name for name, doc in docs.items() for d in doc.get("deleteRules") or []}


def rules_from(docs):
    rules = []
    for name, doc in docs.items():
        for group in doc.get("groups") or []:
            for rule in group.get("rules") or []:
                rules.append((name, group, rule))
    return rules


def provisioned_datasource_uids():
    doc = yaml.safe_load(DATASOURCES_FILE.read_text()) or {}
    return {d["uid"] for d in doc.get("datasources") or []}, doc


def rule_datasource_problems(rule, known_uids):
    problems = []
    for query in rule.get("data") or []:
        uid = query.get("datasourceUid")
        if uid in EXPRESSION_UIDS:
            continue
        if uid not in known_uids:
            problems.append(f"refId {query.get('refId')} reads unknown datasource uid {uid!r}")
    text = json.dumps(rule)
    for marker in FROZEN_MARKERS:
        if marker in text:
            problems.append(f"names the frozen home ClickHouse ({marker})")
    return problems


def check_static():
    known_uids, ds_doc = provisioned_datasource_uids()
    known_uids |= PRIVATE_DATASOURCE_UIDS
    docs = load_yaml_files(ALERTING_DIR)
    rules = rules_from(docs)

    if not rules:
        fail(f"no alert rules found under {ALERTING_DIR}; the glob or the path is wrong")
    seen = {}
    for name, _group, rule in rules:
        uid = rule.get("uid")
        if uid in seen:
            fail(f"rule uid {uid} is defined in both {seen[uid]} and {name}")
        seen[uid] = name
        problems = rule_datasource_problems(rule, known_uids) + host_liveness_nodata_problems(rule)
        for p in problems:
            fail(f"{name}: rule {uid} {p}")
    if rules and not failures:
        ok(
            f"{len(rules)} rules in {len(docs)} files read only provisioned datasources, name no frozen store,"
            f" and every {HOST_LIVENESS_UID_PREFIX}* rule reports NoData when its metric vanishes"
        )
    for uid, name in deleted_uids_from(docs).items():
        if uid in seen:
            fail(f"rule {uid} is defined in {seen[uid]} and deleted in {name}")

    for d in ds_doc.get("datasources") or []:
        text = json.dumps(d)
        for marker in FROZEN_MARKERS:
            if marker in text:
                fail(f"{DATASOURCES_FILE.name}: datasource {d.get('uid')} names the frozen home ClickHouse ({marker})")
        if "clickhouse" in str(d.get("type", "")):
            host = (d.get("jsonData") or {}).get("host")
            if host != LIVE_CLICKHOUSE_HOST:
                fail(f"{DATASOURCES_FILE.name}: ClickHouse datasource {d.get('uid')} host is {host!r}, not {LIVE_CLICKHOUSE_HOST}")

    receivers = {cp["name"] for doc in docs.values() for cp in doc.get("contactPoints") or []}
    policy_receivers = set()

    def walk(policy):
        if policy.get("receiver"):
            policy_receivers.add(policy["receiver"])
        for child in policy.get("routes") or []:
            walk(child)

    for doc in docs.values():
        for policy in doc.get("policies") or []:
            walk(policy)
    missing = policy_receivers - receivers
    if missing:
        fail(f"notification policy routes to contact points that are not provisioned: {sorted(missing)}")
    elif policy_receivers:
        ok(f"notification policy routes only to provisioned contact points: {sorted(policy_receivers)}")
    else:
        fail("no notification policy found; every rule would go nowhere")

    # Planted negative controls, one per detector, so neither gate can pass on the other's strength: a copy of a
    # real rule must be rejected when it names an unknown datasource uid alone, and again when it keeps its known
    # uid but names the frozen store.
    if rules:
        for label, plant in (
            ("an unknown datasource uid", lambda q: q.__setitem__("datasourceUid", "clickhouse-home-frozen")),
            (
                "the frozen store under a known uid",
                lambda q: q.setdefault("model", {}).__setitem__("url", "http://100.65.193.30:18123"),
            ),
        ):
            planted = copy.deepcopy(rules[0][2])
            target = next(q for q in planted.get("data") or [] if q.get("datasourceUid") not in EXPRESSION_UIDS)
            plant(target)
            if rule_datasource_problems(planted, known_uids):
                ok(f"negative control: a rule naming {label} is rejected")
            else:
                fail(f"NEGATIVE CONTROL DID NOT TRIP: a rule naming {label} passed the datasource gate")

    # CTC-5149 controls, same planted convention. The negative control flips a real host rule's
    # noDataState back to OK and must be rejected; the positive control proves the same gate passes
    # the rule as committed, so the gate is not a tripwire that fires unconditionally.
    host_rule = next((r for _, _, r in rules if str(r.get("uid", "")).startswith(HOST_LIVENESS_UID_PREFIX)), None)
    if host_rule is not None:
        planted = copy.deepcopy(host_rule)
        planted["noDataState"] = "OK"
        if host_liveness_nodata_problems(planted):
            ok(f"negative control: a {HOST_LIVENESS_UID_PREFIX}* rule with noDataState OK is rejected")
        else:
            fail(f"NEGATIVE CONTROL DID NOT TRIP: a {HOST_LIVENESS_UID_PREFIX}* rule with noDataState OK passed")
        if not host_liveness_nodata_problems(host_rule):
            ok(f"positive control: the no-data gate passes {host_rule['uid']} as committed (NoData)")
        else:
            fail(f"POSITIVE CONTROL FAILED: the no-data gate rejects committed rule {host_rule['uid']}")
    return rules


def parse_duration(value):
    if value in (None, "", 0):
        return 0
    if isinstance(value, (int, float)):
        return int(value)
    total = 0
    for amount, unit in re.findall(r"(\d+)([smhd])", str(value)):
        total += int(amount) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
    return total


def subset_mismatch(expected, actual, path=""):
    """Every key the file sets must hold the same value live. Grafana adds defaults (intervalMs, maxDataPoints),
    so extra live keys are not drift."""
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path or '.'}: file has a map, live has {type(actual).__name__}"]
        out = []
        for key, value in expected.items():
            out += subset_mismatch(value, actual.get(key), f"{path}.{key}")
        return out
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(expected) != len(actual):
            return [f"{path}: list differs"]
        out = []
        for i, (e, a) in enumerate(zip(expected, actual)):
            out += subset_mismatch(e, a, f"{path}[{i}]")
        return out
    if expected != actual:
        return [f"{path}: file {expected!r} != live {actual!r}"]
    return []


def get_json(base, path):
    with urllib.request.urlopen(base.rstrip("/") + path, timeout=60) as resp:
        return json.load(resp)


def post_json(base, path, body):
    req = urllib.request.Request(
        base.rstrip("/") + path, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.load(resp)


def check_live_routing(base):
    """The contact points and the policy root read back as git provisions them, with the env values filled in.
    Header values are never printed."""
    docs = load_yaml_files(ALERTING_DIR)
    want = {
        r["uid"]: (cp["name"], r)
        for doc in docs.values()
        for cp in doc.get("contactPoints") or []
        for r in cp.get("receivers") or []
    }
    live = {cp["uid"]: cp for cp in get_json(base, "/api/v1/provisioning/contact-points")}
    for uid, (name, receiver) in sorted(want.items()):
        cp = live.get(uid)
        if cp is None:
            fail(f"contact point receiver {uid} ({name}) is not provisioned live")
            continue
        settings = cp.get("settings") or {}
        problems = []
        if cp.get("name") != name or cp.get("type") != receiver.get("type"):
            problems.append(f"live is {cp.get('name')!r}/{cp.get('type')!r}")
        if cp.get("provenance") != "file":
            problems.append(f"provenance is {cp.get('provenance')!r}")
        url = str(settings.get("url", ""))
        if not url.startswith("https://") or "unconfigured" in url:
            problems.append("webhook url is unset or still the placeholder")
        for header in ((receiver.get("settings") or {}).get("headers") or {}):
            if header not in (settings.get("headers") or {}):
                problems.append(f"header {header} is missing")
        for p in problems:
            fail(f"contact point {name}: {p}")
        if not problems:
            ok(f"contact point {name} reads back from file, posting to {url.split('/api/')[0]}")
    policy = get_json(base, "/api/v1/provisioning/policies")
    roots = [p.get("receiver") for doc in docs.values() for p in doc.get("policies") or []]
    if policy.get("receiver") not in roots:
        fail(f"live policy root is {policy.get('receiver')!r}, git says {roots}")
    else:
        ok(f"live policy root routes to {policy.get('receiver')}")


def resolve(hostname):
    """Resolve the way Grafana does: inside its container, whose /etc/hosts and DNS can differ from the host's.
    Falls back to the host's resolver, and says so, when docker is not reachable from here."""
    try:
        out = subprocess.run(
            ["docker", "exec", GRAFANA_CONTAINER, "getent", "hosts", hostname],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if out.returncode == 0 and out.stdout.split():
            return out.stdout.split()[0], f"inside {GRAFANA_CONTAINER}"
    except (OSError, subprocess.TimeoutExpired):
        pass
    try:
        return socket.gethostbyname(hostname), "on this host, not inside the container"
    except OSError as e:
        return None, f"on this host: {e}"


def prometheus_series_count(base, ds, metric):
    """Series count for one metric, read through /api/ds/query as an instant count of the metric's
    last sample inside the lookback. Returns None when the query fails — None is never a pass."""
    now_ms = int(time.time() * 1000)
    body = {
        "queries": [
            {
                "refId": "A",
                "datasource": {"uid": ds["uid"], "type": ds["type"]},
                "expr": f"count(last_over_time({metric}[{PROMETHEUS_SERIES_LOOKBACK}]))",
                "instant": True,
                "range": False,
                "queryType": "instant",
            }
        ],
        "from": str(now_ms - 86400_000),
        "to": str(now_ms),
    }
    try:
        resp = post_json(base, "/api/ds/query", body)
    except Exception as e:  # noqa: BLE001 - an unqueryable metric is not a confirmed series
        print(f"WARN: series count for {metric} failed: {e}")
        return None
    frames = (resp.get("results") or {}).get("A", {}).get("frames") or []
    for frame in frames:
        for values in (frame.get("data") or {}).get("values") or []:
            for value in values:
                if isinstance(value, (int, float)):
                    return int(value)
    return 0


def check_live(base, file_rules, deleted):
    live = {r["uid"]: r for r in get_json(base, "/api/v1/provisioning/alert-rules")}
    files = {rule["uid"]: (name, group, rule) for name, group, rule in file_rules}

    for uid in sorted(set(live) - set(files)):
        if uid in deleted:
            fail(f"live rule {uid} is listed under deleteRules in {deleted[uid]}; restart otel-grafana to apply it")
        else:
            fail(f"live rule {uid} ({live[uid].get('title')}) is not in git")
    for uid in sorted(set(files) - set(live)):
        fail(f"rule {uid} in {files[uid][0]} is not provisioned live")

    drifted = 0
    live_groups = {}
    for uid in sorted(set(live) & set(files)):
        name, group, rule = files[uid]
        lr = live[uid]
        diffs = []
        if lr.get("provenance") != "file":
            diffs.append(f"provenance is {lr.get('provenance')!r}, not 'file' (edited by API or UI)")
        if lr.get("ruleGroup") != group.get("name"):
            diffs.append(f"group file {group.get('name')!r} != live {lr.get('ruleGroup')!r}")
        if parse_duration(rule.get("for")) != parse_duration(lr.get("for")):
            diffs.append(f"for: file {rule.get('for')!r} != live {lr.get('for')!r}")
        for key in ("title", "condition", "labels", "annotations", "noDataState", "execErrState"):
            if key in rule and rule.get(key) != lr.get(key):
                diffs.append(f"{key}: file {rule.get(key)!r} != live {lr.get(key)!r}")
        if bool(rule.get("isPaused", False)) != bool(lr.get("isPaused", False)):
            diffs.append("isPaused differs")
        diffs += subset_mismatch(rule.get("data") or [], lr.get("data") or [], "data")
        live_group = live_groups.get((lr.get("folderUID"), lr.get("ruleGroup")))
        if live_group is None:
            live_group = get_json(base, f"/api/v1/provisioning/folder/{lr.get('folderUID')}/rule-groups/{lr.get('ruleGroup')}")
            live_group["folderTitle"] = get_json(base, f"/api/folders/{lr.get('folderUID')}").get("title")
            live_groups[(lr.get("folderUID"), lr.get("ruleGroup"))] = live_group
        if parse_duration(group.get("interval")) != parse_duration(live_group.get("interval")):
            diffs.append(f"group interval: file {group.get('interval')!r} != live {live_group.get('interval')!r}s")
        if group.get("folder") != live_group.get("folderTitle"):
            diffs.append(f"folder: file {group.get('folder')!r} != live {live_group.get('folderTitle')!r}")
        if diffs:
            drifted += 1
            for d in diffs:
                fail(f"rule {uid} ({name}) drifted: {d}")
    matched = len(set(live) & set(files))
    if not drifted and set(live) == set(files):
        ok(
            f"live Grafana carries exactly the {matched} rules in git: every rule field the files set, plus each"
            f" group's interval and folder ({len(live_groups)} groups)"
        )

    # Planted negative control: a file rule with one query changed must not match its live copy, or the field
    # comparison above is a no-op.
    if matched:
        uid = sorted(set(live) & set(files))[0]
        planted = copy.deepcopy(files[uid][2].get("data") or [])
        planted[0].setdefault("model", {})["ctc5029_planted"] = True
        if subset_mismatch(planted, live[uid].get("data") or [], "data"):
            ok(f"negative control: a changed query on {uid} is reported as drift")
        else:
            fail("NEGATIVE CONTROL DID NOT TRIP: a changed query matched its live copy")

    # CTC-5149: name every alert rule whose Prometheus metrics have all gone quiet. Runs after the
    # drift pass so a dead metric is reported alongside any drift, before routing checks.
    prom_rules = [
        (name, rule)
        for name, _group, rule in file_rules
        if any(q.get("datasourceUid") == "prometheus" for q in rule.get("data") or [])
    ]
    if prom_rules:
        try:
            prom_ds = get_json(base, "/api/datasources/uid/prometheus")
        except Exception as e:  # noqa: BLE001 - without the datasource the gate cannot run
            fail(f"series gate could not read the prometheus datasource, so no-series rules are unproven: {e}")
            prom_ds = None
        if prom_ds is not None:
            for name, rule in prom_rules:
                for p in rule_series_problems(rule, lambda m: prometheus_series_count(base, prom_ds, m)):
                    fail(f"{name}: rule {rule.get('uid')} ({rule.get('title')}) {p}")
            ok(f"series gate read a series count for every Prometheus metric {len(prom_rules)} rules read")
        # Planted controls on the pure decision, canned counts, no network: the gate must reject a
        # rule whose every metric reports zero, and must pass the same rule when series exist.
        planted = copy.deepcopy(prom_rules[0][1])
        target = next(q for q in planted["data"] if q.get("datasourceUid") == "prometheus")
        expr = (target.get("model") or {}).get("expr") or ""
        names = promql_metric_names(expr)
        if names:
            planted_metric = "ctc5149_no_such_metric"
            target["model"]["expr"] = f"count(last_over_time({planted_metric}[{PROMETHEUS_SERIES_LOOKBACK}]))"
            if rule_series_problems(planted, lambda m: 0):
                ok(f"negative control: a rule whose only metric ({planted_metric}) has no series is rejected")
            else:
                fail("NEGATIVE CONTROL DID NOT TRIP: a no-series rule passed the series gate")
            if not rule_series_problems(planted, lambda m: 42):
                ok("positive control: the series gate passes the same rule when its metric has series")
            else:
                fail("POSITIVE CONTROL FAILED: the series gate rejects a rule with series present")
            if promql_metric_names(target["model"]["expr"]) == [planted_metric]:
                ok("metric extraction found the planted metric and no others in the control expr")
            else:
                fail(f"metric extraction on the control expr found {promql_metric_names(target['model']['expr'])}")
        else:
            fail("metric extraction found no metrics in a real Prometheus rule expr; the series gate is blind")

    check_live_routing(base)

    used = sorted(
        {q.get("datasourceUid") for r in live.values() for q in r.get("data") or []} - EXPRESSION_UIDS
    )
    now_ms = int(time.time() * 1000)
    for uid in used:
        ds = get_json(base, f"/api/datasources/uid/{uid}")
        host = (ds.get("jsonData") or {}).get("host") or re.sub(r"^\w+://", "", ds.get("url") or "").split("/")[0]
        hostname = host.split(":")[0]
        if any(m in json.dumps(ds) for m in FROZEN_MARKERS):
            fail(f"datasource {uid} names the frozen home ClickHouse")
        if "clickhouse" not in ds.get("type", ""):
            ok(f"datasource {uid} ({ds.get('type')}) at {host or 'n/a'}")
            continue
        ip, where = resolve(hostname)
        if ip is None:
            fail(f"datasource {uid}: cannot resolve {hostname} ({where})")
            continue
        if ip in FROZEN_IPS:
            fail(f"datasource {uid}: {hostname} resolves to {ip}, the frozen home ClickHouse")
        sql = "SELECT toUnixTimestamp(max(Timestamp)) AS newest, toUnixTimestamp(now()) AS server_now FROM otel.otel_logs WHERE Timestamp > now() - INTERVAL 1 DAY"
        body = {
            "queries": [
                {
                    "refId": "A",
                    "datasource": {"uid": uid, "type": ds["type"]},
                    "rawSql": sql,
                    "format": 1,
                    "queryType": "table",
                    "editorType": "sql",
                }
            ],
            "from": str(now_ms - 3600_000),
            "to": str(now_ms),
        }
        try:
            frame = post_json(base, "/api/ds/query", body)["results"]["A"]["frames"][0]
            newest, server_now = (int(v[0]) for v in frame["data"]["values"])
        except Exception as e:  # noqa: BLE001 - any failure here means freshness is unproven
            fail(f"datasource {uid}: freshness query failed, so freshness is unproven: {e}")
            continue
        age = server_now - newest
        if newest <= 0 or age > FRESHNESS_LIMIT_S:
            fail(f"datasource {uid}: newest otel_logs row is {age}s old (limit {FRESHNESS_LIMIT_S}s)")
        else:
            ok(f"datasource {uid}: {hostname} -> {ip} ({where}), newest otel_logs row {age}s old")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--live", metavar="GRAFANA_URL", help="also compare against a running Grafana (read-only)")
    args = parser.parse_args()

    file_rules = check_static()
    if args.live:
        check_live(args.live, file_rules, deleted_uids_from(load_yaml_files(ALERTING_DIR)))

    if failures:
        print(f"\nAlert rule validation FAILED: {len(failures)} problem(s), see FAIL lines above")
        sys.exit(1)
    print("\nAll alert rule checks passed.")


if __name__ == "__main__":
    main()
