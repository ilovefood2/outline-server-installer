"""Host migration checks without production credentials or host mutations."""
import copy
import unittest
from unittest.mock import patch
import subprocess
from pathlib import Path

from install_on_pi import secure_media_config, sync_state


class MediaConfigTest(unittest.TestCase):
    def test_remove_only_unused_mapping_and_restrict_sources(self):
        data = {'paths': {
            'eufy': {'source': 'rtsp://10.0.0.47/private',
                     'recordPath': '/mnt/eufy/cam-recordings/%path/%Y-%m-%d'},
            'live': {'source': 'publisher'},
            'other': {'recordPath': '/var/lib/mediamtx/recordings/%path'},
        }, 'apiAddress': ':9997', 'rtmp': True, 'rtsp': True,
                'authInternalUsers': [{'user': 'any', 'ips': [], 'permissions': [{'action': 'publish'}]}]}
        kept = copy.deepcopy(data['paths'])
        del kept['eufy']
        self.assertEqual(secure_media_config(data), ['eufy'])
        self.assertEqual(data['paths'], kept)
        self.assertTrue(data['rtmp'] and data['rtsp'])
        self.assertFalse(data['moq'])
        self.assertEqual(data['apiAddress'], '127.0.0.1:9997')
        publishers = [user for user in data['authInternalUsers']
                      if any(p['action'] == 'publish' for p in user['permissions'])]
        self.assertEqual(len(publishers), 1)
        self.assertEqual(publishers[0]['ips'], ['127.0.0.1', '::1', '10.0.0.33'])
        readers = [user for user in data['authInternalUsers']
                   if any(p['action'] == 'read' for p in user['permissions'])]
        self.assertIn('10.0.0.0/24', readers[0]['ips'])
        self.assertEqual(secure_media_config(data), [])

    def test_reject_external_auth_before_mutation(self):
        data = {'authMethod': 'http', 'paths': {'live': {'source': 'publisher'}}}
        original = copy.deepcopy(data)
        with self.assertRaises(RuntimeError):
            secure_media_config(data)
        self.assertEqual(data, original)

    def test_preserve_configured_media_credentials(self):
        data = {'authInternalUsers': [{'user': 'publisher', 'pass': 'fixture-only'}]}
        original = copy.deepcopy(data)
        with self.assertRaises(RuntimeError):
            secure_media_config(data)
        self.assertEqual(data, original)


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

if __name__ == '__main__':
    unittest.main()
