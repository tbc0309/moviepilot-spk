import json
import tempfile
import unittest
from pathlib import Path
from official_plugin_rules import copy_plugins, rules


class OfficialRulesTests(unittest.TestCase):
    def test_versions_and_unknown_changes(self):
        template = '''FROM prepare_payload AS prepare_plugins
ARG MOVIEPILOT_PLUGINS_REF="main"
RUN set -eu;
    cp -a "${plugin_root}/plugins.v2/." /plugins/;
FROM prepare_payload AS prepare_resources
'''
        self.assertEqual(rules(template), ('main', 'plugins.v2', '-'))
        self.assertEqual(rules(template.replace('plugins.v2', 'plugins.v3')), ('main', 'plugins.v3', '-'))
        self.assertEqual(rules(template.replace('/plugins/;', '/plugins/')), ('main', 'plugins.v2', '-'))
        with self.assertRaises(ValueError):
            rules(template.replace('RUN set -eu;', 'RUN execute_new_rule;'))

    def test_common_plugins_without_overwriting(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, dest = root / 'source', root / 'dest'
            for directory, text in [('plugins.v2/example', 'specialized'), ('plugins/example', 'common'), ('plugins/extra', 'extra')]:
                p = source / directory
                p.mkdir(parents=True)
                (p / 'plugin.py').write_text(text)
            (source / 'package.json').write_text(json.dumps({'Example': {'v2': True}, 'Extra': {'v2': True}, 'Other': {'v2': False}}))
            copy_plugins(source, dest, 'plugins.v2', 'v2')
            self.assertEqual((dest / 'example/plugin.py').read_text(), 'specialized')
            self.assertEqual((dest / 'extra/plugin.py').read_text(), 'extra')
            self.assertFalse((dest / 'other').exists())


if __name__ == '__main__':
    unittest.main()
