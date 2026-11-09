#!/usr/bin/env python3
"""Checks for the simulator workflow. Prints a Markdown summary and exits 1 on
any FAIL, so a failed check is never reported as a pass.

  coco_sim_checks.py selftest <coco-selftest.json>
  coco_sim_checks.py install1 <coco-install-report.json>
  coco_sim_checks.py install2 <report-run1.json> <report-run2.json> <Documents dir>
"""
import hashlib
import json
import os
import sys
import uuid

REQUIRED_SELFTESTS = ["LOCAL-01", "LOCAL-02", "LOCAL-03", "LOCAL-04", "LOCAL-04b", "LOCAL-05", "LOCAL-06",
                      "INSTALL-01", "INSTALL-02", "INSTALL-03", "INSTALL-04"]


def offline_uuid(name):
    h = bytearray(hashlib.md5(("OfflinePlayer:" + name).encode()).digest())
    h[6] = (h[6] & 0x0F) | 0x30
    h[8] = (h[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(h)))


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:  # missing or broken file is a FAIL, not a skip
        print("- **FAIL** cannot read `%s`: %s" % (os.path.basename(path), e))
        return None


def group(report, key):
    return (report or {}).get("groups", {}).get(key, {})


def line(test, ok, detail):
    print("- %s **%s** %s" % (test, "PASS" if ok else "FAIL", detail))
    return ok


def selftest(path):
    print("### Self-test (account layer + installer rules)")
    data = load(path)
    if data is None:
        return False
    ok = True
    for key in REQUIRED_SELFTESTS:
        r = data.get(key)
        if r is None:
            ok &= line(key, False, "missing from results")
        else:
            ok &= line(key, r.get("status") == "PASS", r.get("detail", ""))
    return ok


def install1(path):
    print("### Installer, first Play on a clean simulator (no Microsoft account)")
    r = load(path)
    if r is None:
        return False
    account = r.get("account", "")
    print("- result `%s`, account `%s`, official files allowed `%s`" % (r.get("result"), account, r.get("officialFilesAllowed")))
    for key in ("java", "fabric", "metadata", "libraries", "assets", "cocopack"):
        g = group(r, key)
        print("  - %s: %s valid=%s downloaded=%s blocked=%s failed=%s retries=%s sources=%s %s" % (
            key, g.get("state"), g.get("valid", 0), g.get("downloaded", 0), g.get("blocked", 0), g.get("failed", 0),
            g.get("retries", 0), ",".join(g.get("sources", [])), "; ".join(g.get("problems", []))[:300]))
    local = "kind=Local" in account and "microsoftSession=none" in account and "userType=legacy" in account
    independent = all(group(r, k).get("state") == "READY" for k in ("java", "fabric", "cocopack"))
    # Local installs the whole game, as on CocoLauncher Android
    mojang_ok = r.get("officialFilesAllowed") is True and r.get("result") == "READY" and \
        all(group(r, k).get("state") == "READY" for k in ("metadata", "libraries", "assets"))
    mojang_detail = "Minecraft metadata=%s libraries=%s assets=%s, result %s" % (
        group(r, "metadata").get("state"), group(r, "libraries").get("state"), group(r, "assets").get("state"), r.get("result"))
    ok = line("LOCAL-06", local and independent and mojang_ok,
              "Local account (legacy, no Microsoft session) used the shared installer; %s" % mojang_detail)
    ok &= line("LOCAL-07", independent,
               "Java/Fabric/Coco pack prepared without Microsoft: java=%s fabric=%s cocopack=%s" % (
                   group(r, "java").get("state"), group(r, "fabric").get("state"), group(r, "cocopack").get("state")))
    return ok


def install2(path1, path2, docs):
    print("### Close and reopen, Play again")
    r1, r2 = load(path1), load(path2)
    if r1 is None or r2 is None:
        return False
    newer = r2.get("finishedAt", 0) > r1.get("finishedAt", 0)
    no_redownload = all(group(r2, k).get("downloaded", 0) == 0 and group(r2, k).get("state") == "READY"
                        for k in ("fabric", "cocopack"))
    same_account = r1.get("account") == r2.get("account") and "kind=Local" in r2.get("account", "")
    ok = line("LOCAL-10", newer and no_redownload and same_account,
              "second run newer=%s, fabric downloaded=%s, cocopack downloaded=%s (valid=%s), same Local account=%s" % (
                  newer, group(r2, "fabric").get("downloaded", 0), group(r2, "cocopack").get("downloaded", 0),
                  group(r2, "cocopack").get("valid", 0), same_account))
    name = "CocoTester"
    expected = offline_uuid(name)
    f = os.path.join(docs, "accounts", "local-%s.json" % expected)
    acc = load(f) if os.path.exists(f) else None
    files = sorted(os.listdir(os.path.join(docs, "accounts"))) if os.path.isdir(os.path.join(docs, "accounts")) else []
    acc_ok = acc is not None and acc.get("username") == name and acc.get("profileId") == expected and \
        acc.get("type") == "local" and not any(k in acc for k in ("xuid", "xboxGamertag", "accessToken", "msaRefreshToken", "storageId"))
    ok &= line("LOCAL-02", acc_ok, "after app restart: accounts/%s present=%s, files=%s" % (os.path.basename(f), acc is not None, files))
    return ok


def main():
    cmd = sys.argv[1]
    if cmd == "selftest":
        ok = selftest(sys.argv[2])
    elif cmd == "install1":
        ok = install1(sys.argv[2])
    elif cmd == "install2":
        ok = install2(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        raise SystemExit("unknown command " + cmd)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
