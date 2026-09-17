#!/usr/bin/env python3
"""Listens for commands sent from the notification buttons on the phone.

WHY THIS SHAPE (and not a listener that opens a port):
  - No port is opened on the server: no firewall rule, no TLS, no certificate,
    no reverse proxy. The connection goes outward (long poll).
  - It runs as a systemd service OUTSIDE Docker, so the button still works when
    every container is dead — which is exactly when it is needed. Proven on the
    CMR host: all containers down, the site returning nothing, and the button
    brought everything back.
  - The command topic is a SEPARATE secret from the alert topic. If the alert
    topic leaks, nobody can restart the server with it.

Buttons publish with 'Cache: no', so ntfy does not store the command and a
restart of this service cannot replay an old one. The timestamp filter below is
the second layer of the same protection.
"""
import fcntl
import json
import os
import subprocess
import time
import urllib.request

ENV_FILE = os.environ.get("UCS_ENV", "/etc/ucs/ucs.env")
OPS_DIR = os.path.dirname(os.path.abspath(__file__))
COMPOSE_FILE = os.path.join(OPS_DIR, "docker-compose.yml")
NOTIFY = os.path.join(OPS_DIR, "notify.sh")
CONTAINER = "ucs-web"
COOLDOWN = 60                          # seconds between accepted commands
LOCK_FILE = "/var/lock/ucs-ops.lock"   # shared with the watchdog, see below
READ_TIMEOUT = 120                     # ntfy keepalives every ~45s; silence = dead link


def env(key):
    try:
        with open(ENV_FILE) as fh:
            for line in fh:
                if line.startswith(key + "="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def notify(title, body, prio="default", tag="", ops=False):
    """ops=True attaches the restart and reset buttons to the message."""
    try:
        subprocess.run(["sh", NOTIFY, title, body, prio, tag, "",
                        "ops" if ops else ""], timeout=20, check=False)
    except Exception:
        pass


def log(msg):
    print(msg, flush=True)


def docker_alive():
    try:
        return subprocess.run(["docker", "info"], capture_output=True,
                              timeout=30).returncode == 0
    except Exception:
        return False


def ensure_docker():
    """Try to revive the Docker daemon before giving up.

    Compose can do nothing without it, and "restart failed" is a useless answer
    to someone holding a phone. Repair first, then say what to press next.
    """
    if docker_alive():
        return True
    log("docker daemon not responding — restarting it")
    subprocess.run(["systemctl", "restart", "docker"], capture_output=True, check=False)
    for _ in range(15):
        time.sleep(2)
        if docker_alive():
            log("docker daemon is back")
            return True
    return False


def container_running():
    p = subprocess.run(["docker", "inspect", "-f", "{{.State.Status}}", CONTAINER],
                       capture_output=True, text=True)
    return p.stdout.strip() == "running"


def do_restart():
    notify("Yeniden başlatılıyor",
           "Butona bastın. Site yeniden başlıyor, yaklaşık yarım dakika sürer.",
           "default", "arrows_counterclockwise")

    if not ensure_docker():
        notify("Docker bozuk",
               "Yeniden başlatma yapılamadı: Docker servisi yanıt vermiyor ve "
               "kendi kendine de kalkmadı.\n\n"
               "Sunucuyu resetle butonuna bas — bu durumu genelde çözer.",
               "urgent", "rotating_light", ops=True)
        return

    # One compose operation at a time: the watchdog must not start a second one
    # while this is mid-flight. Measured on the CMR host — two racing compose
    # runs corrupted the stack and a service disappeared entirely.
    lock = open(LOCK_FILE, "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        r = subprocess.run(["docker", "compose", "-f", COMPOSE_FILE,
                            "up", "-d", "--force-recreate", "--remove-orphans"],
                           capture_output=True, timeout=300)
        for _ in range(30):            # health gate can take 20-30s
            if container_running():
                break
            time.sleep(2)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()

    if r.returncode == 0 and container_running():
        notify("Yeniden başlatıldı", "Site ayakta ve çalışıyor.",
               "default", "white_check_mark")
    else:
        notify("Yeniden başlatma başarısız",
               "Komut çalıştı ama site ayağa kalkmadı.\n"
               "Sunucuyu resetle butonunu dene.",
               "urgent", "rotating_light", ops=True)


def do_reboot():
    # Send the message FIRST — after the reboot there is no chance.
    notify("Sunucu resetleniyor",
           "Butona bastın. Sunucu yeniden başlıyor, site 1-2 dakika içinde geri gelir.",
           "default", "arrows_counterclockwise")
    time.sleep(2)
    subprocess.run(["systemctl", "reboot"], check=False)


COMMANDS = {"restart": do_restart, "reboot": do_reboot}


def main():
    topic = env("NTFY_CMD_TOPIC")
    if not topic:
        log("NTFY_CMD_TOPIC is not set — exiting")
        return
    # No `since` parameter: the default is already "new messages only".
    # ("since=now" is rejected with HTTP 400 — tried.)
    url = "https://ntfy.sh/%s/json" % topic
    started = time.time()
    last_action = 0.0
    log("command listener started")

    while True:
        try:
            with urllib.request.urlopen(url, timeout=READ_TIMEOUT) as resp:
                for raw in resp:
                    try:
                        msg = json.loads(raw.decode("utf-8"))
                    except ValueError:
                        continue
                    if msg.get("event") != "message":
                        continue
                    if msg.get("time", 0) < started:
                        continue          # predates this process: ignore
                    cmd = (msg.get("message") or "").strip().lower()
                    fn = COMMANDS.get(cmd)
                    if not fn:
                        log("unknown command ignored: %r" % cmd[:40])
                        continue
                    now = time.time()
                    if now - last_action < COOLDOWN:
                        # Do not swallow it silently: whoever pressed the button
                        # is waiting for something to happen.
                        log("cooldown — ignored: %s" % cmd)
                        notify("Zaten yeniden başlıyor",
                               "Az önce bir yeniden başlatma başladı.\n"
                               "Bitmesini bekle, gerekirse tekrar bas.",
                               "low", "hourglass")
                        continue
                    last_action = now
                    log("running command: %s" % cmd)
                    try:
                        fn()
                    except Exception as exc:
                        log("command failed: %s" % exc)
        except Exception as exc:
            log("connection dropped (%s) — retrying in 5s" % exc)
            time.sleep(5)


if __name__ == "__main__":
    main()
