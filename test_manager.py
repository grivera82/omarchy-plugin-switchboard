import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import manager


class ManagerTests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "version": 1,
            "idle": {"lock": 300},
            "bar": {"layout": {
                "left": [{"id": "menu"}],
                "center": [{"id": "clock", "format": "HH:mm"}, {"id": "other"},
                           {"id": "clock", "timezone": "Europe/London"}],
                "right": [{"id": "audio"}]}},
            "plugins": [{"id": "service", "custom": 42}]
        }

    def test_multiple_instances_roundtrip(self):
        saved = manager.snapshot(self.config, "clock")
        changed = copy.deepcopy(self.config)
        changed["bar"]["layout"]["center"] = [{"id": "other"}, {"id": "clock"}]
        self.assertEqual(manager.restore(changed, "clock", saved), self.config)

    def test_preserves_unrelated_changes(self):
        saved = manager.snapshot(self.config, "clock")
        changed = copy.deepcopy(self.config)
        changed["bar"]["layout"]["center"] = [{"id": "new"}, {"id": "other"}, {"id": "clock"}]
        changed["idle"]["lock"] = 900
        manager.restore(changed, "clock", saved)
        self.assertEqual(changed["idle"]["lock"], 900)
        self.assertEqual([e["id"] for e in changed["bar"]["layout"]["center"]],
                         ["new", "clock", "other", "clock"])

    def test_service_settings_roundtrip(self):
        changed = copy.deepcopy(self.config)
        changed["plugins"] = [{"id": "service"}]
        self.assertEqual(manager.restore(changed, "service", manager.snapshot(self.config, "service")), self.config)

    def test_self_and_active_bar_are_protected(self):
        plugins = [{"id": manager.PLUGIN_ID, "enabled": True},
                   {"id": "bar", "enabled": True, "canDisable": False}]
        with patch.object(manager, "catalog", return_value=plugins), patch.object(manager, "run") as run:
            for plugin_id in (manager.PLUGIN_ID, "bar"):
                with self.assertRaises(ValueError):
                    manager.toggle(plugin_id, False)
            run.assert_not_called()

    def test_failed_enable_never_writes_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "shell.json"
            config.write_text(json.dumps(self.config))
            plugin = {"id": "clock", "name": "Clock", "enabled": False, "kinds": ["bar-widget"]}
            with patch.object(manager, "CONFIG", config), patch.object(manager, "STATE", Path(directory)), \
                 patch.object(manager, "catalog", return_value=[plugin]), \
                 patch.object(manager, "run", side_effect=RuntimeError("not running")):
                with self.assertRaises(RuntimeError):
                    manager.toggle("clock", True)
                self.assertEqual(json.loads(config.read_text()), self.config)


if __name__ == "__main__":
    unittest.main()
