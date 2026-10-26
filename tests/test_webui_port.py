#!/usr/bin/env python3
"""Port selection and persisted discovery without a real daemon."""
import json
import os
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "lib"))
from webui_port import choose_port


class WebUIPortTests(unittest.TestCase):
    def test_available_preferred_port_is_preserved(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.assertEqual(choose_port(port), port)

    def test_occupied_port_uses_a_bindable_fallback(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            preferred = listener.getsockname()[1]
            selected = choose_port(preferred)
            self.assertNotEqual(selected, preferred)
            self.assertIn(selected, range(18080, 19000))
            with socket.socket() as check:
                check.bind(("127.0.0.1", selected))

    def test_setup_persists_fallback_and_probe_discovers_it(self):
        with tempfile.TemporaryDirectory() as tmp, socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            preferred = listener.getsockname()[1]
            conf = Path(tmp) / ".config/qBittorrent/qBittorrent.conf"
            conf.parent.mkdir(parents=True)
            conf.write_text(f"[Preferences]\nWebUI\\Port={preferred}\n")
            env = {k: v for k, v in os.environ.items() if not k.startswith("QBT_")}
            env.update(QBT_HOME=tmp, QBT_CONF=str(conf), QBT_STATE_DIR=tmp + "/state",
                       QBT_SKIP_SYSTEMCTL="1", QBT_INSTALLED="1", QBT_DAEMON="0",
                       QBT_LOCK="none", QBT_NET_DIR=tmp + "/no-net")
            subprocess.run([str(ROOT / "qbt"), "start-daemon"], env=env,
                           check=True, capture_output=True, text=True)
            probe = subprocess.run([str(ROOT / "qbt"), "probe"], env=env,
                                   check=True, capture_output=True, text=True)
            base = json.loads(probe.stdout)["base"]
            selected = int(base.rsplit(":", 1)[1])
            self.assertNotEqual(selected, preferred)
            self.assertIn(f"WebUI\\Port={selected}\n", conf.read_text())
            # A later setup keeps the available fallback rather than hopping.
            subprocess.run([str(ROOT / "qbt"), "start-daemon"], env=env,
                           check=True, capture_output=True, text=True)
            self.assertIn(f"WebUI\\Port={selected}\n", conf.read_text())

            # A later login can find the persisted port occupied too. Run
            # the actual pre-start command written into the systemd drop-in.
            import shlex
            drop_in = Path(tmp) / '.config/systemd/user/omaqbt-nox.service.d/webui-port.conf'
            command = drop_in.read_text().split('ExecStartPre=', 1)[1].strip()
            with socket.socket() as later_service:
                later_service.bind(('127.0.0.1', selected))
                later_service.listen()
                subprocess.run(shlex.split(command), env=env, check=True,
                               capture_output=True, text=True, timeout=5)
            probe = subprocess.run([str(ROOT / 'qbt'), 'probe'], env=env,
                                   check=True, capture_output=True, text=True)
            restarted = int(json.loads(probe.stdout)['base'].rsplit(':', 1)[1])
            self.assertNotEqual(restarted, selected)
            self.assertIn(restarted, range(18080, 19000))
            self.assertIn(f'WebUI\\Port={restarted}\n', conf.read_text())

    def test_bad_configured_ports_recover_during_setup(self):
        for value in ('invalid', '0', '-1', '65536', '80@example.invalid'):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                conf = Path(tmp) / '.config/qBittorrent/qBittorrent.conf'
                conf.parent.mkdir(parents=True)
                conf.write_text(f'[Preferences]\nWebUI\\Port={value}\n')
                unit = Path(tmp) / '.config/systemd/user/omaqbt-nox.service'
                unit.parent.mkdir(parents=True)
                custom_unit = '[Service]\nExecStart=/usr/bin/qbittorrent-nox\nRestartSec=10\n'
                unit.write_text(custom_unit)
                env = {k: v for k, v in os.environ.items() if not k.startswith('QBT_')}
                env.update(QBT_HOME=tmp, QBT_CONF=str(conf), QBT_STATE_DIR=tmp + '/state',
                           QBT_SKIP_SYSTEMCTL='1', QBT_INSTALLED='1', QBT_DAEMON='0',
                           QBT_LOCK='none', QBT_NET_DIR=tmp + '/no-net')
                subprocess.run([str(ROOT / 'qbt'), 'start-daemon'], env=env,
                               check=True, capture_output=True, text=True)
                saved = int(conf.read_text().split('WebUI\\Port=', 1)[1].splitlines()[0])
                self.assertTrue(saved == 8080 or saved in range(18080, 19000))
                self.assertEqual(unit.read_text(), custom_unit)
                self.assertTrue(Path(str(unit) + '.d/webui-port.conf').exists())

    def test_exhausted_fallback_range_fails_without_using_ephemeral_port(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            port = listener.getsockname()[1]
            with patch('webui_port.FALLBACK_PORTS', [port]):
                with self.assertRaisesRegex(OSError, 'No available WebUI port'):
                    choose_port(port)

    def test_invalid_ports_are_rejected(self):
        for port in (0, -1, 65536):
            with self.subTest(port=port), self.assertRaises(ValueError):
                choose_port(port)
