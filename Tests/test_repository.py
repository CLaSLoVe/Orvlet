"""Portable regression coverage for publication guards and MCP capabilities."""
import importlib.util
import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


repository = load('repository_check', 'scripts/repository_check.py')
runner = load('check_runner', 'scripts/check.py')
mcp = load('mcp_adapter', 'integrations/mcp/server.py')


class PublicationChecks(unittest.TestCase):
    def test_private_artifacts_are_rejected_even_if_tracked(self):
        for path in ['.build-old/app', '.backups/snapshot', '.local/result.json', 'dist/Orvlet.app/Contents/file', 'Orvlet.xcodeproj/xcuserdata/person/state', '.env.production', 'bridge.json', 'signing.p12', 'Tests/session.json', 'Tests/page.jsonl']:
            with self.subTest(path=path):
                self.assertTrue(repository.forbidden_path(path))

    def test_source_and_reviewed_docs_are_allowed(self):
        for path in ['Orvlet/MyApp.swift', 'Tests/mock_server.py', 'Tests/AppChecks/SelfCheck.swift', 'Orvlet/Resources/adblock-rules.json', 'README.md', '.env.example']:
            self.assertFalse(repository.forbidden_path(path))

    def test_secret_detection_never_echoes_the_value(self):
        sample = 'sk-' + 'a' * 30
        findings = repository.inspect_text('example.swift', sample)
        self.assertTrue(findings)
        self.assertNotIn(sample, '\n'.join(findings))

    def test_personal_paths_are_reported_without_the_value(self):
        sample = '/' + 'Users' + '/private-person/Documents/file'
        findings = repository.inspect_text('example.txt', sample)
        self.assertTrue(findings)
        self.assertNotIn('private-person', '\n'.join(findings))

    def test_dynamic_key_access_is_not_a_secret_literal(self):
        self.assertEqual(repository.inspect_text('example.py', "headers={'Authorization':'Bearer '+settings['token']}"), [])

    def test_script_mirrors_match(self):
        self.assertEqual((ROOT / 'Orvlet/Resources/browser.js').read_bytes(), (ROOT / 'integrations/browser/browser.js').read_bytes())


class CheckRunnerReports(unittest.TestCase):
    def test_stale_report_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            path.write_text(json.dumps({'ok': True, 'checks': ['one']}))
            with self.assertRaises(RuntimeError):
                runner.verify_report(path, time.time() + 1)

    def test_false_or_empty_success_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            for report in [{'ok': False, 'checks': ['one']}, {'ok': True, 'checks': []}]:
                path.write_text(json.dumps(report))
                with self.assertRaises(RuntimeError):
                    runner.verify_report(path, 0)

    def test_both_native_report_formats_are_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            for report in [{'ok': True, 'checks': ['one']}, {'passed': 1, 'checks': ['one']}]:
                path.write_text(json.dumps(report))
                self.assertEqual(runner.verify_report(path, 0), 1)

    def test_default_runner_never_selects_live_scenarios(self):
        self.assertEqual(set(runner.SUITES), {'self', 'side-screen', 'command-window', 'listening', 'protection'})


class MCPInterface(unittest.TestCase):
    def test_html_proposal_has_a_finish_path(self):
        tools = {t['name']: t for t in mcp.handle({'method': 'tools/list'})['tools']}
        schema = tools['orvlet_compose_ui']['inputSchema']
        self.assertIn('markup', schema['properties'])
        self.assertIn('markup', schema['required'])
        self.assertIn('actions', schema['properties'])
        self.assertIn('readings', schema['properties'])
        self.assertIn('media_playing', tools['orvlet_finish']['inputSchema']['properties']['outcome']['enum'])
        self.assertIn('orvlet_reuse_ui', tools)

    def test_list_tools_over_stdio_needs_no_app_or_credential(self):
        request = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}) + '\n'
        result = subprocess.run([sys.executable, str(ROOT / 'integrations/mcp/server.py')], input=request, text=True, capture_output=True, check=True, timeout=5)
        response = json.loads(result.stdout)
        self.assertEqual(response['id'], 1)
        self.assertTrue(response['result']['tools'])


if __name__ == '__main__':
    unittest.main()
