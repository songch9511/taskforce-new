"""Focused lifecycle checks; no build, signing, app, or credentials required."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('dev_mac', Path(__file__).with_name('dev-mac.py'))
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)


class DevMacTests(unittest.TestCase):
    def test_snapshot_ignores_outputs_and_detects_saved_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'local.xcconfig'
            config.write_text('SETTING=YES')
            source = root / 'View.swift'
            source.write_text('before')
            for name in ['.build', 'build', 'DerivedData', '.git', 'custom-derived']:
                folder = root / name
                folder.mkdir()
                (folder / 'ignored.swift').write_text('ignored')
            before = dev.snapshot(root, config, root / 'custom-derived')
            self.assertEqual(set(before), {str(config), str(source)})
            source.write_text('after edit')
            self.assertNotEqual(before, dev.snapshot(root, config, root / 'custom-derived'))
            source.unlink()
            self.assertNotIn(str(source), dev.snapshot(root, config, root / 'custom-derived'))

    def test_failed_build_keeps_running_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            control = Path(directory)
            running = control / 'run-existing' / 'Taskforce.app'
            running.mkdir(parents=True)
            marker = running / 'still-running'
            marker.write_text('original')
            args = SimpleNamespace(derived_data=control, xcconfig=control / 'local.xcconfig')
            with patch.object(dev, 'run', side_effect=RuntimeError('build failed')):
                with self.assertRaises(RuntimeError):
                    dev.prepare(args, control)
            self.assertEqual(marker.read_text(), 'original')

    def test_failed_staging_cleans_only_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            control = Path(directory)
            running = control / 'run-existing'
            running.mkdir()
            args = SimpleNamespace(derived_data=control, xcconfig=control / 'local.xcconfig')
            with patch.object(dev, 'run', side_effect=[None, RuntimeError('copy failed')]):
                with self.assertRaises(RuntimeError):
                    dev.prepare(args, control)
            self.assertEqual(list(control.glob('run-*')), [running])

    def test_stop_targets_only_owned_live_process(self):
        ended = Mock()
        ended.poll.return_value = 0
        dev.stop(ended)
        ended.terminate.assert_not_called()
        owned = Mock()
        owned.poll.return_value = None
        owned.wait.side_effect = [subprocess.TimeoutExpired('owned', 10), 0]
        dev.stop(owned)
        owned.terminate.assert_called_once()
        owned.kill.assert_called_once()

    def test_watch_keeps_restored_app_after_launch_failure_until_next_save(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / 'local.xcconfig'
            config.write_text('SETTING=YES')
            reference = root / 'Installed.app'
            reference.mkdir()
            old_folder, candidate_folder = root / 'run-old', root / 'run-candidate'
            old_folder.mkdir()
            candidate_folder.mkdir()
            old_executable, candidate = old_folder / 'Taskforce', candidate_folder / 'Taskforce'
            old, failed, restored = Mock(pid=1), Mock(pid=2), Mock(pid=3)
            old.poll.return_value = restored.poll.return_value = None
            failed.poll.return_value = 1
            snapshots = iter([{'a': [1, 1]}, {'a': [1, 1]}, {'a': [2, 1]}, {'a': [2, 1]}, {'a': [2, 1]}])

            def observe(*_):
                try:
                    return next(snapshots)
                except StopIteration:
                    restored.terminate.assert_not_called()
                    self.assertFalse(candidate_folder.exists())
                    self.assertTrue(old_folder.exists())
                    raise KeyboardInterrupt()

            argv = ['dev-mac.py', '--watch', '--xcconfig', str(config), '--derived-data', str(root / 'dd'),
                    '--reference-app', str(reference), '--signing-identity', 'test']
            with patch('sys.argv', argv), patch.object(dev, 'snapshot', side_effect=observe), \
                    patch.object(dev, 'prepare', side_effect=[(old_folder, old_executable), (candidate_folder, candidate)]), \
                    patch.object(dev.subprocess, 'Popen', side_effect=[old, failed, restored]) as launch, \
                    patch.object(dev.time, 'sleep'), patch.object(dev, 'write_state') as state:
                self.assertEqual(dev.main(), 0)
            self.assertEqual(launch.call_count, 3)
            self.assertEqual(launch.call_args_list[2].args[0], [str(old_executable)])
            self.assertIn('launch-failed', [call.args[1] for call in state.call_args_list])
            restored.terminate.assert_called_once()  # Only the intentional Ctrl-C shuts it down.

    def test_ready_snapshot_round_trips(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_snapshot = {'file.swift': [123, 50]}
            dev.publish_ready(root, root / 'run-one/Taskforce.app/Contents/MacOS/Taskforce', source_snapshot)
            import json
            self.assertEqual(json.loads((root / 'ready.json').read_text())['snapshot'], source_snapshot)
            self.assertFalse((root / 'ready.tmp').exists())


if __name__ == '__main__':
    unittest.main()
