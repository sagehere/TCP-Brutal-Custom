#!/usr/bin/env python3
"""Persist TCP Brutal port counters exported by brutalctl port-stats."""
import json
import os
import sqlite3
import subprocess
import time

STATE_DIR = "/var/lib/tcp-brutal-custom"
DB_PATH = os.path.join(STATE_DIR, "traffic.sqlite3")
BRUTALCTL = "/usr/local/bin/brutalctl"


def read_counters():
    result = subprocess.run([BRUTALCTL, "port-stats"], text=True,
                            capture_output=True, timeout=10, check=True)
    counters = {}
    for line in result.stdout.splitlines():
        fields = dict(item.split("=", 1) for item in line.split() if "=" in item)
        if "port" in fields:
            counters[int(fields["port"])] = (int(fields.get("sent", 0)),
                                               int(fields.get("retrans", 0)))
    return counters


def database():
    os.makedirs(STATE_DIR, mode=0o755, exist_ok=True)
    db = sqlite3.connect(DB_PATH)
    db.executescript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS baseline (
          port INTEGER PRIMARY KEY, sent INTEGER NOT NULL, retrans INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS daily (
          day TEXT NOT NULL, port INTEGER NOT NULL, sent INTEGER NOT NULL,
          retrans INTEGER NOT NULL, PRIMARY KEY(day, port));
    """)
    return db


def collect():
    now = time.strftime("%Y-%m-%d", time.localtime())
    oldest = time.strftime("%Y-%m-%d", time.localtime(time.time() - 365 * 86400))
    current = read_counters()
    with database() as db:
        db.execute("DELETE FROM daily WHERE day < ?", (oldest,))
        for port, (sent, retrans) in current.items():
            old = db.execute("SELECT sent, retrans FROM baseline WHERE port=?", (port,)).fetchone()
            previous_sent, previous_retrans = old if old else (sent, retrans)
            # A module reload resets its counters. Start a fresh baseline instead of
            # treating the unsigned wrap as traffic.
            delta_sent = sent - previous_sent if sent >= previous_sent else 0
            delta_retrans = retrans - previous_retrans if retrans >= previous_retrans else 0
            db.execute("INSERT INTO baseline(port,sent,retrans) VALUES(?,?,?) "
                       "ON CONFLICT(port) DO UPDATE SET sent=excluded.sent,retrans=excluded.retrans",
                       (port, sent, retrans))
            if delta_sent or delta_retrans:
                db.execute("INSERT INTO daily(day,port,sent,retrans) VALUES(?,?,?,?) "
                           "ON CONFLICT(day,port) DO UPDATE SET sent=sent+excluded.sent,"
                           "retrans=retrans+excluded.retrans",
                           (now, port, delta_sent, delta_retrans))


if __name__ == "__main__":
    collect()
