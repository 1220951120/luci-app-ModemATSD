import os
import pathlib
import subprocess
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SWITCH = ROOT / "root/usr/bin/modem-sim-switch-AK68.sh"
CBI = ROOT / "luasrc/model/cbi/modem5700-AK68.lua"
INIT = ROOT / "root/usr/share/modem-AK68/MT5700-AK68.sh"


class ModemSimSwitchTests(unittest.TestCase):
    def test_web_apply_switches_and_verifies_before_saving_uci(self):
        source = CBI.read_text(encoding="utf-8")
        self.assertIn("function simsel.write", source)
        switch = source.index("/usr/bin/modem-sim-switch-AK68.sh")
        save = source.index("self.map:set", switch)
        self.assertLess(switch, save)
        self.assertIn("function m.on_after_commit", source)
        self.assertNotIn('local apply = luci.http.formvalue("cbi.apply")', source)

    def test_mt5700_init_uses_the_same_verified_switch(self):
        source = INIT.read_text(encoding="utf-8")
        self.assertIn('/usr/bin/modem-sim-switch-AK68.sh "$Sim_Sel"', source)
        self.assertNotIn("AT^SCICHG=0,1", source)
        self.assertNotIn("AT^SCICHG=1,0", source)

    def test_switch_is_verified_and_repeated_request_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temp:
            temp_path = pathlib.Path(temp)
            modem_state = temp_path / "modem-state"
            runtime_state = temp_path / "runtime-state"
            init_log = temp_path / "init-log"
            command_log = temp_path / "commands"
            mock = temp_path / "atsd_tools_cli"
            modem_state.write_text("0,1\n", encoding="utf-8")
            mock.write_text(
                textwrap.dedent(
                    f"""\
                    #!/bin/sh
                    command=''
                    while [ "$#" -gt 0 ]; do
                        [ "$1" = -c ] && {{ shift; command="$1"; break; }}
                        shift
                    done
                    printf '%s\\n' "$command" >> {command_log}
                    case "$command" in
                        'AT^SCICHG?')
                            printf '^SCICHG: '
                            cat {modem_state}
                            echo OK
                            ;;
                        AT^SCICHG=*)
                            printf '%s\\n' "${{command#AT^SCICHG=}}" > {modem_state}
                            echo OK
                            ;;
                        AT^HVSST=*) echo OK ;;
                        *) exit 1 ;;
                    esac
                    """
                ),
                encoding="utf-8",
            )
            mock.chmod(0o755)
            env = os.environ.copy()
            env.update(
                {
                    "MODEM_SIM_LOCK_FILE": str(temp_path / "switch.lock"),
                    "MODEM_SIM_STATE_FILE": str(runtime_state),
                    "MODEM_SIM_INIT_LOG": str(init_log),
                    "MODEM_SIM_AT_CLIENT": str(mock),
                }
            )

            first = subprocess.run(
                ["sh", str(SWITCH), "1"],
                env=env,
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            self.assertEqual(first.stdout.strip(), "OK")
            self.assertEqual(modem_state.read_text(encoding="utf-8").strip(), "1,0")
            self.assertEqual(runtime_state.read_text(encoding="utf-8").strip(), "1")
            first_commands = command_log.read_text(encoding="utf-8").splitlines()
            self.assertIn("AT^SCICHG=1,0", first_commands)
            self.assertIn("AT^HVSST=1,0", first_commands)
            self.assertIn("AT^HVSST=1,1", first_commands)

            command_log.write_text("", encoding="utf-8")
            second = subprocess.run(
                ["sh", str(SWITCH), "1"],
                env=env,
                check=False,
                text=True,
                capture_output=True,
            )
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            self.assertEqual(command_log.read_text(encoding="utf-8").splitlines(), ["AT^SCICHG?"])


if __name__ == "__main__":
    unittest.main()
