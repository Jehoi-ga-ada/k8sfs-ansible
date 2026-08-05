#!/usr/bin/env python3
import base64
import json
import os
import sys
import urllib.request

BASE = os.environ["ORCHARD_URL"]
USER = os.environ["ORCHARD_SERVICE_ACCOUNT_NAME"]
PW = os.environ["ORCHARD_SERVICE_ACCOUNT_TOKEN"]
AUTH = "Basic " + base64.b64encode(f"{USER}:{PW}".encode()).decode()


def get(path):
    req = urllib.request.Request(BASE + path, headers={"Authorization": AUTH})
    with urllib.request.urlopen(req, timeout=40) as r:
        return r.read().decode()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--host":
        print("{}")
        return

    inv = {"_meta": {"hostvars": {}}}
    for vm in json.loads(get("/v1/vms")):
        if vm.get("status") != "running":
            continue
        name = vm["name"]
        try:
            body = get(f"/v1/vms/{name}/ip?wait=30")
            ip = (
                json.loads(body).get("ip", body).strip()
                if body.startswith("{")
                else body.strip()
            )
        except Exception:
            continue
        role = name.rsplit("-", 1)[0]
        inv.setdefault(role, {"hosts": []})["hosts"].append(name)
        inv["_meta"]["hostvars"][name] = {"ansible_host": ip}
    print(json.dumps(inv, indent=4))


main()
