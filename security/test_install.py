"""Host migration checks without production credentials or host mutations."""
import copy
import unittest

from install_on_pi import secure_media_config


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


if __name__ == '__main__':
    unittest.main()
