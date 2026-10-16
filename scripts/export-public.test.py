import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).with_name('export-public.py')


class PublicExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = pathlib.Path(self.tmp.name) / 'source'
        self.source.mkdir()
        self.output = pathlib.Path(self.tmp.name) / 'public'
        self.write('README.md', '# Example\n')

    def write(self, name, text):
        path = self.source / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def run_export(self):
        self.assertTrue(SCRIPT.exists(), 'public exporter is not implemented')
        return subprocess.run([sys.executable, str(SCRIPT), str(self.output),
                               '--source', str(self.source)], capture_output=True, text=True)

    def test_leaks_abort_without_output_or_printing_values(self):
        samples = {
            'credential': 'Bearer ' + 'fixtureSecret' * 3,
            'personal-path': '/Users/' + 'private-person/Documents/work',
            'personal-account': 'com.' + 'privateperson.codexpocket',
            'network-address': '10.' + '23.45.67',
            'session-id': '01a00000-' + '0000-0000-0000-000000000000',
            'certificate-pin': 'pinnedCertSHA256 = "' + 'a' * 64 + '"',
        }
        for category, sample in samples.items():
            with self.subTest(category=category):
                self.output = pathlib.Path(self.tmp.name) / category
                self.write('connector/config.mjs', sample)
                result = self.run_export()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(category, result.stderr)
                self.assertIn('connector/config.mjs', result.stderr)
                self.assertNotIn(sample, result.stderr)
                self.assertFalse(self.output.exists())

    def test_allowlist_exports_source_without_history_or_runtime_data(self):
        for name in ['.git/config', 'work/run.log', 'docs/HANDOFF.md',
                     'connector/config.json', 'connector/private.pem',
                     'CodexPocket/Core/RPCClient.swift', 'node_modules/x/a.js',
                     'CodexPocketUITests/LiveTests.swift']:
            self.write(name, 'private fixture')
        for name in ['connector/cli.mjs', 'bridge/bridge.mjs',
                     'CodexPocket/App/Main.swift', 'docs/public/setup.md',
                     'packaging/sea-config.json', 'scripts/build-connector.mjs',
                     'packaging/Start.cmd', 'packaging/Start.command',
                     'packaging/README.txt', 'bridge/ui.html', 'connector/web/index.html',
                     'connector/web/style.css', 'connector/web/app.js',
                     'scripts/fixtures/image.png',
                     'scripts/fixtures/state-data.mjs', 'licenses/example/LICENSE',
                     'CodexPocketTests/SendTests.swift',
                     'CodexPocketUITests/AwardStateTests.swift',
                     'CodexPocketUITests/Info.plist']:
            self.write(name, 'public fixture')
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        files = {str(p.relative_to(self.output)) for p in self.output.rglob('*') if p.is_file()}
        self.assertIn('connector/cli.mjs', files)
        self.assertIn('docs/public/setup.md', files)
        self.assertIn('packaging/sea-config.json', files)
        self.assertIn('packaging/Start.cmd', files)
        self.assertIn('packaging/Start.command', files)
        self.assertIn('packaging/README.txt', files)
        self.assertIn('connector/web/index.html', files)
        self.assertIn('connector/web/style.css', files)
        self.assertIn('bridge/ui.html', files)
        self.assertIn('connector/web/app.js', files)
        self.assertIn('scripts/fixtures/image.png', files)
        self.assertIn('scripts/fixtures/state-data.mjs', files)
        self.assertIn('licenses/example/LICENSE', files)
        self.assertNotIn('work/run.log', files)
        self.assertNotIn('connector/config.json', files)
        self.assertNotIn('CodexPocket/Core/RPCClient.swift', files)
        self.assertNotIn('CodexPocketUITests/LiveTests.swift', files)
        self.assertFalse((self.output / '.git').exists())

    def test_literal_credentials_and_private_hosts_are_rejected(self):
        for category, sample in [
                ('credential', 'token = "' + 'a' * 32 + '"'),
                ('personal-hostname', 'https://fixture.' + 'kdns.fr/ws')]:
            with self.subTest(category=category):
                self.output = pathlib.Path(self.tmp.name) / category
                self.write('connector/config.mjs', sample)
                result = self.run_export()
                self.assertIn(category, result.stderr)
                self.assertFalse(self.output.exists())

    def test_only_reviewed_url_test_examples_are_normalized(self):
        self.write('CodexPocketTests/BridgeURLTests.swift',
                   'https://' + '8.8.' + '4.4/ws https://fixture.' + 'kdns.fr/ws')
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        text = (self.output / 'CodexPocketTests/BridgeURLTests.swift').read_text()
        self.assertIn('203.0.113.10', text)
        self.assertIn('relay.example', text)

    def test_export_project_keeps_only_mock_ui_references(self):
        keep, dead, build, group = ('A' * 24, 'B' * 24, 'C' * 24, 'D' * 24)
        pbx = (f'{keep} /* AwardStateTests.swift */ = {{isa = PBXFileReference; }};\n'
               f'{dead} /* LiveTests.swift */ = {{isa = PBXFileReference; }};\n'
               f'{build} /* LiveTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {dead}; }};\n'
               f'{group} /* CodexPocketUITests */ = {{isa = PBXGroup; children = ('
               f'{keep} /* AwardStateTests.swift */, {dead} /* LiveTests.swift */, ); }};\n')
        self.write('CodexPocket.xcodeproj/project.pbxproj', pbx)
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        exported = (self.output / 'CodexPocket.xcodeproj/project.pbxproj').read_text()
        self.assertIn(keep, exported)
        self.assertNotIn(dead, exported)
        self.assertNotIn(build, exported)
        self.assertEqual((self.source / 'CodexPocket.xcodeproj/project.pbxproj').read_text(), pbx)

    def test_unmodified_license_bytes_are_preserved(self):
        path = self.source / 'licenses/example/LICENSE'
        path.parent.mkdir(parents=True)
        content = b'Copyright \xa9 Example\n'
        path.write_bytes(content)
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.output / 'licenses/example/LICENSE').read_bytes(), content)

    def test_exported_default_scheme_skips_ui_tests(self):
        name = 'CodexPocket.xcodeproj/xcshareddata/xcschemes/CodexPocket.xcscheme'
        self.write(name, '<Scheme><TestAction><Testables>'
                   '<TestableReference skipped="NO"><BuildableReference BlueprintName="CodexPocketUITests"/>'
                   '</TestableReference></Testables></TestAction></Scheme>')
        result = self.run_export()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('skipped="YES"', (self.output / name).read_text())
        self.assertIn('skipped="NO"', (self.source / name).read_text())

    def test_malformed_scheme_is_rejected_without_traceback(self):
        self.write('CodexPocket.xcodeproj/xcshareddata/xcschemes/Bad.xcscheme', '<Scheme')
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unsupported-scheme', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse(self.output.exists())

    def test_rejects_symlink_and_existing_output(self):
        self.write('connector/cli.mjs', 'safe fixture')
        link = self.source / 'connector/leak.mjs'
        link.symlink_to(self.source / 'README.md')
        result = self.run_export()
        self.assertIn('symlink', result.stderr)
        self.assertFalse(self.output.exists())
        link.unlink()
        self.output.mkdir()
        (self.output / 'keep').write_text('keep')
        result = self.run_export()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.output / 'keep').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
