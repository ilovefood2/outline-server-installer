"""Host migration checks without production credentials or host mutations."""
import unittest
from unittest.mock import patch
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory

from install_on_pi import sync_state, restore_checkpoint


class StateSyncTest(unittest.TestCase):
    def test_only_online_copy_accepts_vanished_files(self):
        with patch('install_on_pi.subprocess.run', return_value=subprocess.CompletedProcess([], 24)):
            sync_state(Path('/fixture'), live=True)
            with self.assertRaises(RuntimeError):
                sync_state(Path('/fixture'))

    def test_partial_transfer_always_aborts(self):
        with patch('install_on_pi.subprocess.run', return_value=subprocess.CompletedProcess([], 23)):
            for live in (False, True):
                with self.assertRaises(RuntimeError):
                    sync_state(Path('/fixture'), live=live)

    def test_checkpoint_restore_retains_raw_database(self):
        with TemporaryDirectory() as directory:
            staging = Path(directory)
            data = staging / 'prometheus/data'
            snapshot = data / 'snapshots/fixture/block'
            snapshot.mkdir(parents=True)
            (snapshot / 'index').write_bytes(b'preserved history')
            (data / 'wal').mkdir()
            (data / 'wal/000001').write_bytes(b'raw recovery log')
            restore_checkpoint(staging, 'fixture')
            self.assertEqual((data / 'block/index').read_bytes(), b'preserved history')
            self.assertFalse((data / 'wal').exists())
            self.assertEqual((data.parent / 'data-before-security/wal/000001').read_bytes(), b'raw recovery log')
            with self.assertRaises(RuntimeError):
                restore_checkpoint(staging, '../escape')

if __name__ == '__main__':
    unittest.main()
