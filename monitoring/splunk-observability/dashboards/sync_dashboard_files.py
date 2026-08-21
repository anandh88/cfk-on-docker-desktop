#!/usr/bin/env python3
"""
Re-pulls a dashboard's current live state (chart definitions + layout) into its
combined JSON file, so the file on disk never drifts from what's actually live
after a manual PUT/DELETE patch against the API. Reads each chart via
GET /v2/chart/{id} rather than trusting the local copy, so the result is
guaranteed accurate even if the local file was stale or hand-edited.

Usage:
    export SFX_TOKEN=<token>
    python3 sync_dashboard_files.py broker-resources connect-resources ...
    python3 sync_dashboard_files.py --all   # every *.json dashboard file in this dir

One-time migration note: this script originally consolidated the old
one-file-per-chart layout (chart-*.json + dashboard.json in a subdirectory per
dashboard) into today's one-combined-file-per-dashboard format. That migration
already ran for broker-resources, connect-resources, kafka-cluster, and
connect-cluster on 2026-08-21. schema-registry-resources,
kraft-controller-resources, and control-center-resources were deliberately left
in the old scattered format at that time - their dashboard AND all charts had
been found deleted from the org (confirmed via repeated 404s, cause unknown),
so there was nothing live left to consolidate; recreate them from that
directory's JSON first, then run this script against the resulting combined
file same as any other dashboard.
"""
import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_resources_dashboards as b

OUT_ROOT = os.path.dirname(os.path.abspath(__file__))


def sync_one(name):
    path = os.path.join(OUT_ROOT, f"{name}.json")
    with open(path) as fh:
        existing = json.load(fh)

    dash_id = existing["dashboard"]["id"]
    dash = b.api("GET", f"/v2/dashboard/{dash_id}")

    charts = []
    for c in dash["charts"]:
        live = b.api("GET", f"/v2/chart/{c['chartId']}")
        charts.append({
            "id": live["id"],
            "name": live["name"],
            "description": live.get("description"),
            "programText": live["programText"],
            "options": live["options"],
            "layout": {
                "row": c["row"], "column": c["column"],
                "width": c["width"], "height": c["height"],
            },
        })

    combined = {
        "dashboardGroupId": dash["groupId"],
        "dashboard": {
            "id": dash["id"], "name": dash["name"],
            "url": f"https://app.us1.observability.splunkcloud.com/#/dashboard/{dash['id']}",
            "timeRange": dash["filters"]["time"],
        },
        "charts": charts,
    }
    with open(path, "w") as fh:
        json.dump(combined, fh, indent=2)
        fh.write("\n")
    print(f"{name}: {len(charts)} charts re-synced -> {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("names", nargs="*", help="Dashboard file names (without .json) to re-sync")
    parser.add_argument("--all", action="store_true", help="Re-sync every *.json dashboard file in this directory")
    args = parser.parse_args()

    if args.all:
        names = [os.path.splitext(os.path.basename(p))[0]
                  for p in glob.glob(os.path.join(OUT_ROOT, "*.json"))
                  if os.path.basename(p) != "dashboard-group.json"]
    else:
        names = args.names

    if not names:
        parser.error("Pass one or more dashboard names, or --all")

    for name in names:
        sync_one(name)


if __name__ == "__main__":
    main()
