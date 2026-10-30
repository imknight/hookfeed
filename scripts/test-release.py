#!/usr/bin/env python3
"""Local release checks; uses disposable keys and never notarizes or publishes."""
import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('metadata', ROOT / 'scripts/release-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='hookfeed-release-test-')
        cls.folder = Path(cls.temporary.name)
        generator = cls.folder / 'key.swift'
        generator.write_text('''import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: folder.appendingPathComponent("key"))
try Data(key.publicKey.rawRepresentation.base64EncodedString().utf8).write(to: folder.appendingPathComponent("public"))
''')
        subprocess.run(['swift', str(generator), str(cls.folder)], check=True, capture_output=True)
        (cls.folder / 'key').chmod(0o600)
        cls.public_key = (cls.folder / 'public').read_text()
        cls.sparkle = ROOT / '.build-package/artifacts/sparkle/Sparkle/bin'
        cls.config = ('0.2.0', '2', 'https://github.com/example/app/releases/latest/download/appcast.xml', 'example/app', cls.public_key)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.folder))

    def test_tag_repository_and_key_validation(self):
        (self.work / 'Config').mkdir()
        info = plistlib.loads((ROOT / 'Config/Info.plist').read_bytes())
        info.update(CFBundleShortVersionString='0.2.0', CFBundleVersion='2', SUFeedURL='', SUPublicEDKey='')
        original_root = metadata.ROOT
        metadata.ROOT = self.work
        try:
            def save():
                (self.work / 'Config/Info.plist').write_bytes(plistlib.dumps(info))
            save()
            with self.assertRaisesRegex(ValueError, 'Tag must match'):
                metadata.configuration('v9.9.9')
            with self.assertRaisesRegex(ValueError, 'repository placeholder'):
                metadata.configuration('v0.2.0')
            info['SUFeedURL'] = self.config[2]
            save()
            with self.assertRaisesRegex(ValueError, 'SUPublicEDKey'):
                metadata.configuration('v0.2.0')
            info['SUPublicEDKey'] = self.public_key
            save()
            self.assertEqual(metadata.configuration('v0.2.0'), self.config)
            info['CFBundleVersion'] = '2.1'
            save()
            with self.assertRaisesRegex(ValueError, 'positive integer'):
                metadata.configuration('v0.2.0')
        finally:
            metadata.ROOT = original_root

    def test_signature_and_tampering(self):
        archive = self.work / 'archive.zip'
        archive.write_bytes(b'archive fixture')
        signature = subprocess.check_output([str(self.sparkle / 'sign_update'), '--ed-key-file', str(self.folder / 'key'), '-p', str(archive)], text=True).strip()
        command = ['swift', str(ROOT / 'scripts/verify-update-signature.swift'), str(archive), self.public_key, signature]
        subprocess.run(command, check=True, capture_output=True)
        archive.write_bytes(b'archive altered')  # Same length, so the signature must detect this.
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('signature verification failed', result.stderr)

    def test_cumulative_appcast_and_enclosure_validation(self):
        source = ROOT / 'dist/HookFeed.app'
        self.assertTrue(source.is_dir(), 'Run scripts/build-app.sh before this test')
        archives = self.work / 'archives'
        archives.mkdir()
        app = self.work / 'HookFeed.app'
        subprocess.run(['ditto', str(source), str(app)], check=True)
        plist = app / 'Contents/Info.plist'
        for version, build in [('0.1.0', '1'), ('0.2.0', '2')]:
            info = plistlib.loads(plist.read_bytes())
            info.update(CFBundleShortVersionString=version, CFBundleVersion=build, SUPublicEDKey=self.public_key, SUFeedURL=self.config[2])
            plist.write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
            archive = archives / f'HookFeed-{version}.zip'
            subprocess.run(['ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
            if build == '2':
                metadata.check_build(archives / 'appcast.xml', build)
            subprocess.run([str(self.sparkle / 'generate_appcast'), '--ed-key-file', str(self.folder / 'key'), '--maximum-versions', '0', '--maximum-deltas', '0', '--versions', build, '--download-url-prefix', f'https://github.com/example/app/releases/download/v{version}/', str(archives)], check=True, capture_output=True)
            if build == '1':
                first_item = ET.tostring(metadata.items(archives / 'appcast.xml')[0])
                archive.unlink()  # A release only downloads the prior XML, not prior archives.
        feed = archives / 'appcast.xml'
        entries = metadata.items(feed)
        self.assertEqual(len(entries), 2)
        self.assertEqual(ET.tostring(entries[1]), first_item)
        url, length, signature = metadata.enclosure(feed, self.config)
        archive = archives / 'HookFeed-0.2.0.zip'
        self.assertEqual(int(length), archive.stat().st_size)
        subprocess.run(['swift', str(ROOT / 'scripts/verify-update-signature.swift'), str(archive), self.public_key, signature], check=True, capture_output=True)
        with self.assertRaisesRegex(ValueError, 'exceed every build'):
            metadata.check_build(feed, '2')
        metadata.check_build(feed, '3')
        for field, value in [('url', 'https://example.com/wrong.zip'), ('length', '0'), (metadata.SPARKLE + 'edSignature', 'invalid')]:
            tree = ET.parse(feed)
            tree.find('./channel/item/enclosure').set(field, value)
            invalid = self.work / 'invalid.xml'
            tree.write(invalid)
            with self.assertRaises(ValueError):
                metadata.enclosure(invalid, self.config)
        with self.assertRaisesRegex(ValueError, 'version/build'):
            metadata.enclosure(feed, ('0.3.0', '3', *self.config[2:]))


if __name__ == '__main__':
    unittest.main()
