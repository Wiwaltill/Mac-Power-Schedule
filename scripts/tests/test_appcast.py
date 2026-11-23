import base64
import importlib.util
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location('make_appcast', Path(__file__).parents[1] / 'make-appcast.py')
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)

class AppcastTests(unittest.TestCase):
    signature = base64.b64encode(bytes(range(64))).decode()
    def test_feed_points_to_exact_release_and_signed_archive(self):
        data = appcast.make_feed('0.3.0', 'v0.3.0', self.signature, 12345, 'Wiwaltill/Mac-Power-Schedule')
        item = ET.fromstring(data).find('channel/item')
        self.assertEqual(item.findtext(f'{{{appcast.NAMESPACE}}}version'), '0.3.0')
        self.assertEqual(item.findtext(f'{{{appcast.NAMESPACE}}}minimumSystemVersion'), '13.0.0')
        enclosure = item.find('enclosure')
        self.assertEqual(enclosure.get('url'), 'https://github.com/Wiwaltill/Mac-Power-Schedule/releases/download/v0.3.0/Mac-Power-Schedule.zip')
        self.assertEqual(enclosure.get('length'), '12345')
        self.assertEqual(enclosure.get(f'{{{appcast.NAMESPACE}}}edSignature'), self.signature)
    def test_rejects_mismatched_or_unsafe_release_metadata(self):
        for version, tag, repository in [
            ('0.3.0', 'v0.2.1', 'Wiwaltill/Mac-Power-Schedule'),
            ('0.3.0', 'v0.3.0', 'owner/repo?redirect=bad'),
            ('0.3.0;command', 'v0.3.0;command', 'owner/repo'),
        ]:
            with self.subTest(tag=tag, repository=repository), self.assertRaises(ValueError):
                appcast.make_feed(version, tag, self.signature, 123, repository)
    def test_rejects_missing_signature_or_empty_archive(self):
        for signature, length in [('', 123), ('not-a-signature', 123), (self.signature, 0)]:
            with self.subTest(length=length), self.assertRaises(ValueError):
                appcast.make_feed('0.3.0', 'v0.3.0', signature, length, 'owner/repo')

if __name__ == '__main__':
    unittest.main()
