# SPDX-License-Identifier: GPL-3.0-only
"""Exercise the actual guide renderer/sinks without running the packaging CLI."""
from pathlib import Path
from urllib.parse import urlsplit
import ast
import io
import re
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
PACKAGER = ROOT / "scripts/package_release.py"


class InstallationLinkTests(unittest.TestCase):
    revision = "f" * 40
    targets = ("host/windows/README.md", "docs/BRAND_COMPATIBILITY.md",
               "docs/RELEASING.md", "docs/HEADLESS_WINDOWS.md")

    @classmethod
    def setUpClass(cls):
        cls.tree = ast.parse(PACKAGER.read_text(encoding="utf-8"))
        functions = [node for node in cls.tree.body if isinstance(node, ast.FunctionDef)
                     and node.name == "render_installation_links"]
        if len(functions) != 1:
            raise AssertionError("Expected one production installation-guide renderer")
        namespace = {"re": re, "urlsplit": urlsplit}
        exec(compile(ast.Module(body=functions, type_ignores=[]), str(PACKAGER), "exec"), namespace)
        cls.render = staticmethod(namespace["render_installation_links"])

    def test_each_known_target_is_pinned_and_fragment_is_preserved(self):
        for path in self.targets:
            for fragment in ("", "#설치-안내", "#"):
                with self.subTest(path=path, fragment=fragment):
                    text = "[guide](" + path + fragment + ")"
                    self.assertEqual(self.render(text, self.revision),
                                     "[guide](https://github.com/ictechgy/Knot/blob/" + self.revision
                                     + "/" + path + fragment + ")")

    def test_https_and_document_local_anchors_are_unchanged(self):
        for target in ("https://example.invalid/guide?mode=preview#install", "#파일-전송", "#"):
            with self.subTest(target=target):
                text = "[guide](" + target + ")"
                self.assertEqual(self.render(text, self.revision), text)

    def test_reference_destinations_titles_and_angle_wrappers_are_preserved(self):
        text = ('[guide]: <docs/RELEASING.md#build> "Build guide"\n'
                '[web]: https://example.invalid/path "Web guide"\n'
                '[local]: #설치\n'
                '[inline-guide](docs/RELEASING.md#build "Inline guide")\n'
                '[inline](<https://example.invalid/path> "Inline title")')
        expected = text.replace('docs/RELEASING.md#build',
                                'https://github.com/ictechgy/Knot/blob/' + self.revision + '/docs/RELEASING.md#build')
        self.assertEqual(self.render(text, self.revision), expected)
        with self.assertRaises(ValueError):
            self.render('[unknown]: docs/missing.md "Unknown"', self.revision)

    def test_unknown_relative_or_non_https_links_are_rejected(self):
        for target in ("docs/missing.md", "docs/missing.md#section", "../host/windows/README.md",
                       "/host/windows/README.md", "//example.invalid/guide", "file:///tmp/guide.md",
                       "http://example.invalid/guide", "javascript:alert", "docs/RELEASING.md?raw=1"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                self.render("[guide](" + target + ")", self.revision)

    def test_empty_control_whitespace_and_malformed_https_are_rejected(self):
        for target in ("", "docs/RELEASING.md\n", "docs/RELEASING.md#bad\x00", "#bad anchor",
                       "https://", "https://:443/guide", "https://example.invalid:invalid/guide"):
            with self.subTest(target=target), self.assertRaises(ValueError):
                self.render("[guide](" + target + ")", self.revision)

    def test_mutable_or_malformed_source_revisions_are_rejected(self):
        for revision in ("main", "f" * 39, "f" * 41, "g" * 40, "f" * 40 + "\n"):
            with self.subTest(revision=revision), self.assertRaises(ValueError):
                self.render("[guide](docs/RELEASING.md)", revision)

    def test_actual_guide_rewrites_all_five_relative_links(self):
        original = (ROOT / "INSTALLATION.md").read_text(encoding="utf-8")
        relative = re.findall(r"\]\(((?:host|docs)/[^)]*)\)", original)
        self.assertEqual(len(relative), 5)
        rendered = self.render(original, self.revision)
        self.assertNotRegex(rendered, r"\]\((?:host|docs)/")
        for target in relative:
            self.assertIn("](https://github.com/ictechgy/Knot/blob/" + self.revision + "/" + target + ")",
                          rendered)
        for target in re.findall(r"\]\((https://[^)]*)\)", original):
            self.assertIn("](" + target + ")", rendered)

    def test_actual_three_sinks_write_the_same_utf8_guide(self):
        # Execute only the real renderer call and the three actual document-write
        # expressions against new temporary paths/a memory ZIP. No top-level
        # packager import, compiler, signer, app bundle or network is involved.
        producers = [node for node in ast.walk(self.tree) if isinstance(node, ast.Call)
                     and isinstance(node.func, ast.Name) and node.func.id == "render_installation_links"]
        self.assertEqual(len(producers), 1)
        namespace = {"ROOT": ROOT, "head": self.revision, "render_installation_links": self.render}
        original = (ROOT / "INSTALLATION.md").read_bytes()
        rendered = eval(compile(ast.Expression(body=producers[0]), str(PACKAGER), "eval"), namespace)
        namespace["installation"] = rendered
        sinks = []
        for node in ast.walk(self.tree):
            if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
                continue
            destination = node.func.value
            if (node.func.attr == "write_text" and isinstance(destination, ast.BinOp)
                    and isinstance(destination.right, ast.Constant)
                    and destination.right.value == "INSTALLATION.md"):
                sinks.append(node)
            elif (node.func.attr in ("write", "writestr") and any(
                    isinstance(arg, ast.Constant) and arg.value == "Knot-Windows-Setup/INSTALLATION.md"
                    for arg in node.args)):
                sinks.append(node)
        self.assertEqual(len(sinks), 3)
        with tempfile.TemporaryDirectory(prefix="knot-installation-guide-") as directory:
            stage = Path(directory) / "mac-stage"; stage.mkdir()
            output = Path(directory) / "release-output"; output.mkdir()
            memory = io.BytesIO()
            with zipfile.ZipFile(memory, "w") as archive:
                namespace.update(stage=stage, output=output, archive=archive)
                for sink in sinks:
                    eval(compile(ast.Expression(body=sink), str(PACKAGER), "eval"), namespace)
            expected = rendered.encode("utf-8")
            self.assertEqual((stage / "INSTALLATION.md").read_bytes(), expected)
            self.assertEqual((output / "INSTALLATION.md").read_bytes(), expected)
            with zipfile.ZipFile(memory) as archive:
                self.assertEqual(archive.read("Knot-Windows-Setup/INSTALLATION.md"), expected)
        self.assertEqual((ROOT / "INSTALLATION.md").read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
