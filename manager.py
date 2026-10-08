#!/usr/bin/env python3
"""Use Omarchy's CLI for lifecycle changes; remember only this manager's toggles."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

PLUGIN_ID = "grivera.switchboard"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "omarchy/shell.json"
STATE = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "omarchy/switchboard"


def run(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "Omarchy command failed")
    return result.stdout.strip()


def catalog():
    return json.loads(run("omarchy", "plugin", "list", "--json"))


def atomic_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".switchboard-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        if path.exists():
            os.chmod(name, path.stat().st_mode & 0o777)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def snapshot(config, plugin_id):
    saved = []
    for section, entries in config.get("bar", {}).get("layout", {}).items():
        for index, entry in enumerate(entries):
            if entry.get("id") == plugin_id:
                saved.append({"section": section, "index": index, "entry": entry,
                              "before": entries[index + 1].get("id") if index + 1 < len(entries) else "",
                              "after": entries[index - 1].get("id") if index else ""})
    for index, entry in enumerate(config.get("plugins", [])):
        if entry.get("id") == plugin_id:
            saved.append({"section": "plugins", "index": index, "entry": entry})
    return saved


def restore(config, plugin_id, saved):
    """Patch only this plugin, retaining unrelated changes and nearby widget order."""
    layout = config.setdefault("bar", {}).setdefault("layout", {})
    for section in ("left", "center", "right"):
        layout[section] = [e for e in layout.get(section, []) if e.get("id") != plugin_id]
    config["plugins"] = [e for e in config.get("plugins", []) if e.get("id") != plugin_id]
    for item in saved:
        section = item["section"]
        entries = config["plugins"] if section == "plugins" else layout[section]
        index = min(item["index"], len(entries))
        before = next((i for i, e in enumerate(entries) if e.get("id") == item.get("before")), None)
        after = next((i for i, e in enumerate(entries) if e.get("id") == item.get("after")), None)
        if before is not None:
            index = before
        elif after is not None:
            index = after + 1
        entries.insert(index, item["entry"])
    return config


def toggle(plugin_id, enabled):
    plugins = catalog()
    plugin = next((p for p in plugins if p["id"] == plugin_id), None)
    if plugin is None:
        raise ValueError("Plugin is no longer installed. Refresh the list.")
    if plugin_id == PLUGIN_ID:
        raise ValueError("Switchboard stays enabled. Disable it using the terminal if needed.")
    if not enabled and not plugin.get("canDisable", True):
        raise ValueError("Choose another bar to replace the active bar.")
    if plugin["enabled"] == enabled:
        return "Already " + ("enabled" if enabled else "disabled")

    memory_path = STATE / "placements.json"
    memory = json.loads(memory_path.read_text()) if memory_path.exists() else {}
    if not enabled:
        config = json.loads(CONFIG.read_text()) if CONFIG.exists() else {}
        # Clone switching is owned by Omarchy; restoring raw clone entries would
        # bypass its source-replacement rules.
        if not plugin.get("clonedFrom"):
            memory[plugin_id] = snapshot(config, plugin_id)
            atomic_json(memory_path, memory)
        # Omarchy removes one widget instance per disable call.
        for _ in range(100):
            run("omarchy", "plugin", "disable", plugin_id)
            current = next(p for p in catalog() if p["id"] == plugin_id)
            if not current["enabled"]:
                break
        else:
            raise RuntimeError("Could not disable all instances of this plugin")
    else:
        run("omarchy", "plugin", "enable", plugin_id)
        saved = memory.get(plugin_id)
        if saved and not plugin.get("clonedFrom") and "bar" not in plugin["kinds"]:
            previous = CONFIG.read_text()
            config = restore(json.loads(previous), plugin_id, saved)
            if CONFIG.read_text() != previous:
                raise RuntimeError("Layout changed during the toggle. Plugin is enabled; retry after refreshing.")
            atomic_json(CONFIG, config)
            result = run("omarchy-shell", "shell", "reloadConfig")
            if result != "ok":
                raise RuntimeError("Could not reload the restored layout")
    actual = next(p for p in catalog() if p["id"] == plugin_id)
    if actual["enabled"] != enabled:
        raise RuntimeError("Omarchy did not apply the requested state")
    return plugin["name"] + (" enabled" if enabled else " disabled")


def main():
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "manager.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        message = ""
        if len(sys.argv) > 1 and sys.argv[1] == "toggle":
            if len(sys.argv) != 4 or sys.argv[3] not in ("true", "false"):
                raise ValueError("Usage: manager.py toggle <id> <true|false>")
            message = toggle(sys.argv[2], sys.argv[3] == "true")
        elif len(sys.argv) != 2 or sys.argv[1] != "list":
            raise ValueError("Usage: manager.py list | toggle <id> <true|false>")
        print(json.dumps({"ok": True, "plugins": catalog(), "message": message}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired, StopIteration) as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        sys.exit(1)
