#!/usr/bin/env python3
"""Sign the final notarized archive and its Sparkle feed. Never print key material."""
import datetime
import email.utils
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NAMESPACE)

def make_feed(version, tag, signature, length, repository):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or tag not in (version, 'v' + version):
        raise ValueError('Version and release tag must match')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid GitHub repository')
    if not re.fullmatch(r'[A-Za-z0-9+/]{86}==', signature):
        raise ValueError('Invalid Ed25519 archive signature')
    if length <= 0:
        raise ValueError('Empty archive')
    rss = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'Mac Power Schedule'
    ET.SubElement(channel, 'link').text = 'https://github.com/' + repository
    ET.SubElement(channel, 'description').text = 'Signierte Updates für Mac Power Schedule'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'Mac Power Schedule ' + version
    ET.SubElement(item, 'link').text = f'https://github.com/{repository}/releases/tag/{tag}'
    ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc), usegmt=True)
    ET.SubElement(item, f'{{{NAMESPACE}}}version').text = version
    ET.SubElement(item, f'{{{NAMESPACE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{NAMESPACE}}}minimumSystemVersion').text = '13.0.0'
    ET.SubElement(item, 'description').text = 'Neue Version von Mac Power Schedule. Änderungen und Hinweise stehen auf der verlinkten Release-Seite.'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{repository}/releases/download/{tag}/Mac-Power-Schedule.zip',
        'length': str(length), 'type': 'application/octet-stream',
        f'{{{NAMESPACE}}}edSignature': signature,
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding='utf-8', xml_declaration=True)

def main():
    version = os.environ.get('APP_VERSION', (ROOT / 'VERSION').read_text().strip())
    tag = os.environ.get('RELEASE_TAG', 'v' + version)
    repository = os.environ.get('GITHUB_REPOSITORY', 'Wiwaltill/Mac-Power-Schedule')
    archive = ROOT / 'dist/Mac-Power-Schedule.zip'
    tool = ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'
    key = os.environ.get('SPARKLE_PRIVATE_KEY')
    args = [str(tool), '--account', 'de.wiwaltill.MacPowerSchedule']
    if key:
        verification = subprocess.run(['swift', str(ROOT / 'scripts/verify-sparkle-key.swift'), str(ROOT / 'assets/sparkle-public-key.txt')],
                                      input=key.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if verification.returncode:
            raise RuntimeError('Sparkle private key does not match the embedded public key')
        args += ['--ed-key-file', '-']
    else:
        public = subprocess.check_output([str(tool.parent / 'generate_keys'), '--account', 'de.wiwaltill.MacPowerSchedule', '-p'], text=True).strip()
        if public != (ROOT / 'assets/sparkle-public-key.txt').read_text().strip():
            raise RuntimeError('Local Sparkle key does not match the embedded public key')
    def invoke(extra):
        result = subprocess.run(args + extra, input=key.encode() if key else None,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            raise RuntimeError('Sparkle signing/verification failed; no private key was printed')
        return result.stdout.decode().strip()
    signature = invoke(['-p', str(archive)])
    invoke(['--verify', str(archive), signature])
    feed = ROOT / 'dist/appcast.xml'
    feed.write_bytes(make_feed(version, tag, signature, archive.stat().st_size, repository))
    invoke([str(feed), '--disable-signing-warning'])
    invoke(['--verify', str(feed)])
    print('Archive signature and signed appcast verified for ' + tag)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, RuntimeError) as error:
        sys.exit(str(error))
