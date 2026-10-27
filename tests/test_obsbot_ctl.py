#!/usr/bin/env python3
"""Offline tests for obsbot-ctl. Runs in demo mode against fixture-L.txt and
never opens a video device.  Run: python3 -I tests/test_obsbot_ctl.py"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
CTL = os.path.join(HERE, "..", "bin", "obsbot-ctl")
FIXTURE = os.path.join(HERE, "fixture-L.txt")


class ObsbotCtlTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.env = dict(os.environ,
                        OBSBOT_CTL_FAKE=FIXTURE,
                        XDG_RUNTIME_DIR=self.tmp.name,
                        XDG_CONFIG_HOME=os.path.join(self.tmp.name, "config"),
                        XDG_STATE_HOME=os.path.join(self.tmp.name, "state"),
                        PATH="/usr/bin:/bin")
        self.env.pop("OBSBOT_DEVICE", None)

    def tearDown(self):
        self.tmp.cleanup()

    def run_ctl(self, *args, env=None):
        proc = subprocess.run([sys.executable, "-I", CTL] + list(args),
                              capture_output=True, text=True, env=env or self.env)
        return proc.returncode, json.loads(proc.stdout)

    def ctrl(self, name):
        return self.run_ctl("state")[1]["controls"][name]

    def test_state_parses_fixture(self):
        code, s = self.run_ctl("state")
        self.assertEqual(code, 0)
        self.assertTrue(s["present"] and s["fake"])
        c = s["controls"]
        self.assertEqual(len(c), 22)
        self.assertEqual(c["zoom_absolute"], {"type": "int", "min": 0, "max": 12, "step": 1, "default": 0,
                                              "value": 0, "inactive": False, "readonly": False})
        self.assertEqual(c["auto_exposure"]["menu"], {"0": "Auto Mode", "1": "Manual Mode", "3": "Aperture Priority Mode"})
        self.assertEqual(c["power_line_frequency"]["menu"]["1"], "50 Hz")
        self.assertEqual(c["white_balance_automatic"]["max"], 1)
        self.assertTrue(c["focus_absolute"]["inactive"])
        self.assertEqual(s["ai"], {"available": True, "framing": "group", "framingStyle": 1, "hdr": False})

    def test_locked_value_is_skipped_not_failed(self):
        code, s = self.run_ctl("set", "focus_absolute=30")
        self.assertEqual(code, 0)
        self.assertEqual(s["applied"], {})
        self.assertEqual(s["controls"]["focus_absolute"]["value"], 46)

    def test_mode_applied_before_dependent(self):
        # Dependent listed first on purpose: modes must still go first.
        code, s = self.run_ctl("set", "focus_absolute=30", "focus_automatic_continuous=0")
        self.assertEqual(code, 0)
        self.assertEqual(s["applied"], {"focus_automatic_continuous": 0, "focus_absolute": 30})
        self.assertFalse(s["controls"]["focus_absolute"]["inactive"])
        self.assertFalse(self.ctrl("focus_absolute")["inactive"])

    def test_manual_exposure(self):
        code, s = self.run_ctl("set", "auto_exposure=1", "exposure_time_absolute=200")
        self.assertEqual(code, 0)
        self.assertEqual(self.ctrl("exposure_time_absolute")["value"], 200)
        self.run_ctl("set", "auto_exposure=3")
        self.assertTrue(self.ctrl("exposure_time_absolute")["inactive"])

    def test_clamp_and_snap(self):
        self.run_ctl("set", "zoom_absolute=99", "pan_absolute=5000", "white_balance_temperature=4149")
        self.assertEqual(self.ctrl("zoom_absolute")["value"], 12)
        self.assertEqual(self.ctrl("pan_absolute")["value"], 3600)

    def test_bad_values_report_errors(self):
        code, s = self.run_ctl("set", "power_line_frequency=5", "nonsense=1", "zoom_absolute=abc", "zoom_absolute=3")
        self.assertEqual(code, 1)
        self.assertIn("power_line_frequency", s["errors"])
        self.assertIn("nonsense", s["errors"])

    def test_nudge(self):
        self.run_ctl("nudge", "zoom_absolute", "2")
        self.run_ctl("nudge", "zoom_absolute", "-1")
        self.assertEqual(self.ctrl("zoom_absolute")["value"], 1)
        self.run_ctl("nudge", "pan_absolute", "-3")
        self.assertEqual(self.ctrl("pan_absolute")["value"], -3 * 3600)

    def test_reset_skips_invalid_menu_default(self):
        self.run_ctl("set", "zoom_absolute=6", "brightness=80", "focus_automatic_continuous=0")
        code, s = self.run_ctl("reset")
        self.assertEqual(code, 0)
        self.assertEqual(s["controls"]["zoom_absolute"]["value"], 0)
        self.assertEqual(s["controls"]["brightness"]["value"], 50)
        self.assertEqual(s["controls"]["focus_automatic_continuous"]["value"], 1)
        self.assertEqual(s["controls"]["power_line_frequency"]["value"], 1)
        self.assertNotIn("zoom_continuous", s["applied"])

    def test_presets_roundtrip(self):
        self.run_ctl("set", "zoom_absolute=4", "auto_exposure=1", "exposure_time_absolute=150")
        code, s = self.run_ctl("preset", "save", "Desk", "close")
        self.assertEqual(s["presets"], ["Desk close"])
        self.run_ctl("reset")
        code, s = self.run_ctl("preset", "load", "Desk close")
        self.assertEqual(code, 0)
        self.assertEqual(s["controls"]["zoom_absolute"]["value"], 4)
        self.assertEqual(s["controls"]["exposure_time_absolute"]["value"], 150)
        with open(os.path.join(self.tmp.name, "obsbot-ctl-fake-presets.json")) as f:
            saved = json.load(f)["presets"]["Desk close"]
        self.assertNotIn("pan_speed", saved)
        code, s = self.run_ctl("preset", "delete", "Desk close")
        self.assertEqual(s["presets"], [])
        code, s = self.run_ctl("preset", "load", "Desk close")
        self.assertEqual(code, 1)

    def test_restore_reapplies_last(self):
        self.run_ctl("set", "zoom_absolute=5")
        # Simulate a power cycle: the camera comes back with its defaults.
        os.remove(os.path.join(self.tmp.name, "obsbot-ctl-fake.json"))
        self.assertEqual(self.ctrl("zoom_absolute")["value"], 0)
        code, s = self.run_ctl("restore")
        self.assertTrue(s["restored"])
        self.assertEqual(s["controls"]["zoom_absolute"]["value"], 5)

    def test_demo_mode_leaves_real_files_alone(self):
        self.run_ctl("set", "zoom_absolute=5")
        self.run_ctl("preset", "save", "x")
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "config", "obsbot")))
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "state", "obsbot")))

    def test_absent_device(self):
        env = dict(self.env, OBSBOT_DEVICE="/nonexistent/video99")
        env.pop("OBSBOT_CTL_FAKE")
        code, s = self.run_ctl("state", env=env)
        self.assertEqual(code, 0)
        self.assertFalse(s["present"])
        code, s = self.run_ctl("present", env=env)
        self.assertFalse(s["present"])

    def test_ai_status(self):
        code, s = self.run_ctl("ai", "status")
        self.assertEqual(code, 0)
        self.assertEqual((s["framing"], s["framingStyle"], s["hdr"]), ("group", 1, False))

    def test_ai_framing_keeps_style_between_modes(self):
        code, s = self.run_ctl("ai", "framing", "single")
        self.assertEqual((s["framing"], s["framingStyle"]), ("single", 1))
        code, s = self.run_ctl("ai", "framing", "off")
        self.assertEqual((s["framing"], s["framingStyle"]), ("off", 0))
        code, s = self.run_ctl("ai", "framing", "group")
        self.assertEqual((s["framing"], s["framingStyle"]), ("group", 0))
        self.assertEqual(self.run_ctl("state")[1]["ai"]["framing"], "group")

    def test_ai_hdr(self):
        self.assertTrue(self.run_ctl("ai", "hdr", "on")[1]["hdr"])
        self.assertFalse(self.run_ctl("ai", "hdr", "off")[1]["hdr"])

    def test_ai_rejects_bad_args(self):
        self.assertEqual(self.run_ctl("ai", "framing", "whiteboard")[0], 1)
        self.assertEqual(self.run_ctl("ai", "hdr")[0], 1)

    def test_xu_ioctl_number(self):
        # _IOWR('u', 0x21, struct uvc_xu_control_query) on 64-bit Linux
        self.assertEqual(self.load_module().UVCIOC_CTRL_QUERY, 0xc0107521)

    def load_module(self):
        import importlib.machinery, importlib.util
        loader = importlib.machinery.SourceFileLoader("obsbot_ctl", CTL)
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("obsbot_ctl", loader))
        loader.exec_module(mod)
        return mod

    def test_parser_on_real_dump_shape(self):
        # The helper must cope with a `-L` dump that has no menu controls.
        c = self.load_module().parse_controls("\nUser Controls\n\n  brightness 0x00980900 (int)    : min=-64 max=64 step=1 default=0 value=-3\n")
        self.assertEqual(c["brightness"]["value"], -3)
        self.assertEqual(c["brightness"]["min"], -64)


if __name__ == "__main__":
    unittest.main(verbosity=1)
