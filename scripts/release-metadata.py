#!/usr/bin/env python3
import base64
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def configuration(tag):
    with (ROOT / 'Config/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or tag != 'v' + version:
        raise ValueError('Tag must match CFBundleShortVersionString: v' + version)
    if not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('CFBundleVersion must be a positive integer')
    feed = info['SUFeedURL']
    match = re.fullmatch(r'https://github\.com/([\w-]+/[\w.-]+)/releases/latest/download/appcast\.xml', feed)
    if not match:
        raise ValueError('Replace the public repository placeholder in Config/Info.plist SUFeedURL')
    public_key = info['SUPublicEDKey']
    if 'PLACEHOLDER' in public_key or len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('Replace SUPublicEDKey with the real Sparkle public key')
    return version, build, feed, match[1], public_key


def changelog_notes(path, version):
    """Return only this version's CHANGELOG section, or None when the file or section is absent."""
    if not Path(path).is_file():
        return None
    heading = re.compile(r'##\s+\[?v?' + re.escape(version) + r'\]?(\s.*)?')
    lines, section = Path(path).read_text().splitlines(), None
    for line in lines:
        if section is None:
            if heading.fullmatch(line.rstrip()):
                section = []
        elif re.match(r'#{1,2}\s', line):
            break
        elif not re.match(r'\[[^\]]+\]:\s*\S', line):  # Skip link reference definitions.
            section.append(line)
    if section is None:
        return None
    notes = '\n'.join(section).strip()
    if not notes:
        raise ValueError(f'CHANGELOG.md section for {version} is empty')
    return notes + '\n'


def items(path):
    root = ET.parse(path).getroot()
    if root.tag != 'rss' or root.find('channel') is None:
        raise ValueError('Expected an RSS appcast channel')
    result = root.findall('./channel/item')
    for item in result:
        if not re.fullmatch(r'[1-9]\d*', item.findtext(SPARKLE + 'version', '')):
            raise ValueError('Every appcast item must have an integer sparkle:version')
    return result


def check_build(path, build):
    previous = items(path)
    if previous and int(build) <= max(int(item.findtext(SPARKLE + 'version')) for item in previous):
        raise ValueError('CFBundleVersion must exceed every build in the previous appcast')


def enclosure(path, config):
    version, build, _, repository, _ = config
    entries = items(path)
    if not entries:
        raise ValueError('Appcast is empty')
    newest = entries[0]
    if newest.findtext(SPARKLE + 'version') != build or newest.findtext(SPARKLE + 'shortVersionString') != version:
        raise ValueError('Newest appcast item does not match the requested version/build')
    if any(int(item.findtext(SPARKLE + 'version')) >= int(build) for item in entries[1:]):
        raise ValueError('Appcast has a duplicate or newer build after the first item')
    archive = newest.find('enclosure')
    url = f'https://github.com/{repository}/releases/download/v{version}/HookFeed-{version}.zip'
    if archive is None or archive.get('url') != url or archive.get('type') != 'application/octet-stream':
        raise ValueError('Unexpected appcast enclosure URL or type')
    length = archive.get('length', '')
    signature = archive.get(SPARKLE + 'edSignature', '')
    if not re.fullmatch(r'[1-9]\d*', length) or len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Invalid enclosure length or EdDSA signature')
    return url, length, signature


if __name__ == '__main__':
    try:
        command, tag = sys.argv[1:3]
        config = configuration(tag)
        if command == 'config':
            print('\t'.join(config))
        elif command == 'check-build':
            check_build(sys.argv[3], config[1])
        elif command == 'enclosure':
            print('\t'.join(enclosure(sys.argv[3], config)))
        elif command == 'notes':
            notes = changelog_notes(sys.argv[3], config[0])
            if notes is not None:
                sys.stdout.write(notes)
        else:
            raise ValueError('Unknown metadata command')
    except (ValueError, KeyError, ET.ParseError) as error:
        sys.exit(str(error))
