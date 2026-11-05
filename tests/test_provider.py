import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from devsy_aca.provider import Config, Provider, devsy_status, machine_label


class ProviderTests(unittest.TestCase):
    def setUp(self):
        self.group = Mock()
        self.credential = Mock()
        self.provider = Provider(Config("12345678-1234-1234-1234-123456789abc"),
                                 client=self.group, credential=self.credential)
        self.sandbox = Mock(sandbox_id="sandbox-id")
        self.group.get_sandbox_client.return_value = self.sandbox

    def set_sandbox(self, state):
        self.group.list_sandboxes.return_value = [SimpleNamespace(id="sandbox-id", state=state)]
        self.sandbox.get.return_value = SimpleNamespace(state=state)

    def test_devsy_lifecycle_status_contract(self):
        self.group.list_sandboxes.return_value = []
        self.assertEqual(self.provider.status("machine-a"), "NotFound")
        for state, status in {"Running": "Running", "Suspended": "Stopped",
                              "Stopped": "Stopped", "Creating": "Busy",
                              "Stopping": "Busy", "Deleting": "NotFound"}.items():
            with self.subTest(state=state):
                self.set_sandbox(state)
                self.assertEqual(self.provider.status("machine-a"), status)
        with self.assertRaisesRegex(RuntimeError, "failed"):
            devsy_status("Failed")

    def test_create_is_label_scoped_and_has_no_ingress(self):
        self.group.list_sandboxes.return_value = []
        self.group.begin_create_sandbox.return_value.result.return_value = self.sandbox
        with patch.object(self.provider, "bootstrap") as bootstrap:
            self.provider.create("machine-a")
        self.group.list_sandboxes.assert_called_once_with(labels={"devsy-machine": machine_label("machine-a")})
        options = self.group.begin_create_sandbox.call_args.kwargs
        self.assertEqual(options["ports"], [])
        self.assertEqual(options["labels"]["devsy-machine"], machine_label("machine-a"))
        bootstrap.assert_called_once_with(self.sandbox)

    def test_create_reuses_existing_workspace(self):
        self.set_sandbox("Stopped")
        with patch.object(self.provider, "bootstrap") as bootstrap:
            self.provider.create("machine-a")
        self.group.begin_create_sandbox.assert_not_called()
        self.sandbox.ensure_running.assert_called_once()
        bootstrap.assert_called_once_with(self.sandbox)

    def test_bootstrap_failure_rolls_back_only_a_new_sandbox(self):
        self.group.list_sandboxes.return_value = []
        self.group.begin_create_sandbox.return_value.result.return_value = self.sandbox
        with patch.object(self.provider, "bootstrap", side_effect=RuntimeError("bootstrap failed")):
            with self.assertRaisesRegex(RuntimeError, "bootstrap failed"):
                self.provider.create("machine-a")
            self.sandbox.delete.assert_called_once()
            self.sandbox.delete.reset_mock()
            self.set_sandbox("Running")
            with self.assertRaisesRegex(RuntimeError, "bootstrap failed"):
                self.provider.create("machine-a")
            self.sandbox.delete.assert_not_called()

    def test_duplicate_label_refuses_mutation(self):
        self.group.list_sandboxes.return_value = [SimpleNamespace(id="a", state="Running"),
                                                  SimpleNamespace(id="b", state="Running")]
        with self.assertRaisesRegex(RuntimeError, "Multiple sandboxes"):
            self.provider.delete("machine-a")
        self.group.get_sandbox_client.assert_not_called()

    def test_command_preserves_shell_text_and_result(self):
        self.set_sandbox("Running")
        command = "printf '%s\\n' '$VALUE'; exit 23"
        with patch("devsy_aca.provider.run_command", return_value=23) as run:
            self.assertEqual(self.provider.command("machine-a", command), 23)
        run.assert_called_once_with(self.provider.config, "sandbox-id", self.credential, command)
