"""Focused checks for publication exclusions and safe snapshot destinations."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release", Path(__file__).resolve().parents[1] / "scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class SnapshotTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "development"
        self.root.mkdir()
        self.run_git("init", "--quiet")
        for name, content in {
            "README.md": "Public instructions\n",
            "AGENTS.md": "Private instructions\n",
            "lua/nested/AGENTS.local.md": "Nested instructions\n",
            "AGENTS-private/note.txt": "Agent directory\n",
            "docs/architecture.md": "Internal documentation\n",
            "scripts/svg_viewer/viewer.js": "runtime asset\n",
            "lua/lilyp/vendor/NOTICE": "dependency notice\n",
        }.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        self.run_git("add", ".")
        # A tree object suffices; tests never create commits or publication refs.
        self.tree = self.run_git("write-tree").strip()
        (self.root / "untracked.txt").write_text("Do not publish\n")
        self.output = Path(self.temporary.name) / "public snapshot"

    def run_git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True)

    def test_filtered_snapshot_preserves_committed_runtime_bytes(self):
        (self.root / "README.md").write_text("Uncommitted changes\n")
        self.assertEqual(release.export(self.root, self.tree, self.output), self.tree)
        files = {p.relative_to(self.output).as_posix() for p in self.output.rglob("*") if p.is_file()}
        self.assertEqual(files, {"README.md", "scripts/svg_viewer/viewer.js", "lua/lilyp/vendor/NOTICE"})
        self.assertEqual((self.output / "README.md").read_text(), "Public instructions\n")
        self.assertEqual((self.output / "scripts/svg_viewer/viewer.js").read_bytes(),
                         (self.root / "scripts/svg_viewer/viewer.js").read_bytes())
        self.assertFalse((self.output / ".git").exists())

    def test_existing_destination_is_untouched(self):
        self.output.mkdir()
        sentinel = self.output / "keep.txt"
        sentinel.write_text("Keep me\n")
        with self.assertRaises(ValueError):
            release.export(self.root, self.tree, self.output)
        self.assertEqual(sentinel.read_text(), "Keep me\n")

    def test_destination_in_development_repository_is_rejected(self):
        with self.assertRaises(ValueError):
            release.export(self.root, self.tree, self.root / "snapshot")
        self.assertFalse((self.root / "snapshot").exists())

    def test_bad_revision_creates_no_destination(self):
        with self.assertRaises(subprocess.CalledProcessError):
            release.export(self.root, "missing-release", self.output)
        self.assertFalse(self.output.exists())

    def test_external_symlink_is_rejected_before_output(self):
        (self.root / "outside").symlink_to("../outside")
        self.run_git("add", "outside")
        tree = self.run_git("write-tree").strip()
        with self.assertRaises(release.tarfile.TarError):
            release.export(self.root, tree, self.output)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
