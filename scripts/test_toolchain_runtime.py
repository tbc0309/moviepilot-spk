"""工具链库选择的回归测试。"""
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from select_toolchain_runtime import select


class RuntimeSelectionTests(unittest.TestCase):
    def test_reject_debug_script_and_wrong_architecture(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'libstdc++.so.6.0.25-gdb.py').write_text('debugger script')
            wrong = root/'host/libstdc++.so.6.0.25'
            right = root/'target/libstdc++.so.6.0.25'
            for path in (wrong, right):
                path.parent.mkdir()
                path.write_bytes(b'\x7fELFfixture')
            def readelf(argv, **kwargs):
                machine = 'AArch64' if argv[-1] == str(right) else 'Advanced Micro Devices X86-64'
                output = f'Machine: {machine}\n' if argv[1] == '-h' else '(SONAME) [libstdc++.so.6]'
                return subprocess.CompletedProcess(argv, 0, output, '')
            with patch('select_toolchain_runtime.subprocess.run', side_effect=readelf):
                self.assertEqual(select(root, 'libstdc++.so.6', 'rtd1296'), right)

    def test_no_elf_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'libstdc++.so.6').write_text('not an ELF')
            with self.assertRaises(RuntimeError):
                select(root, 'libstdc++.so.6', 'x64')
