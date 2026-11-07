"""Regression checks for the research-only, path-free SNES writer build."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import json

SCRIPT = Path(__file__).with_name("reproduce_tested_writer.py")
BUILD_SCRIPT = SCRIPT.parents[2] / "scripts" / "build-reproduced-snes-writer.py"
EXPECTED = "7d1e5fb9657baa7294790e538eadfc4a1446b233a8839851849fc0c652471e7a"


@unittest.skipUnless(os.environ.get("SNES_TESTED_WRITER_FIXTURE"), "requires a local writer fixture")
class ReproduceTestedWriterTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.source = Path(os.environ["SNES_TESTED_WRITER_FIXTURE"])
        self.output = self.root / "writer"

    def run_tool(self, source=None):
        return subprocess.run(["python3", str(SCRIPT), str(source or self.source), str(self.output)], capture_output=True)

    def test_rebuild_reproduces_checked_executable_without_private_paths(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        payload = self.output.read_bytes()
        self.assertEqual(hashlib.sha256(payload).hexdigest(), EXPECTED)
        self.assertNotIn(b"/Users/", payload)
        self.assertNotIn(b"/Development/NES", payload)
        self.assertEqual(self.output.stat().st_mode & 0o777, 0o500)

    def test_refuses_existing_output_without_changing_it(self):
        self.output.write_bytes(b"keep me")
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertEqual(self.output.read_bytes(), b"keep me")

    def test_refuses_output_symlink_without_touching_its_target(self):
        target = self.root / "target"
        target.write_bytes(b"keep me")
        self.output.symlink_to(target)
        self.assertNotEqual(self.run_tool().returncode, 0)
        self.assertEqual(target.read_bytes(), b"keep me")

    def test_refuses_invalid_input_without_creating_output(self):
        wrong = self.root / "wrong"
        wrong.write_bytes(b"not a writer")
        self.assertNotEqual(self.run_tool(wrong).returncode, 0)
        self.assertFalse(self.output.exists())

    def test_refuses_modified_program_segment_without_creating_output(self):
        changed = bytearray(self.source.read_bytes())
        changed[5000] ^= 1
        wrong = self.root / "modified"
        wrong.write_bytes(changed)
        self.assertNotEqual(self.run_tool(wrong).returncode, 0)
        self.assertFalse(self.output.exists())

    def test_permission_failure_does_not_publish_partial_output(self):
        program = (
            "import os,runpy,sys; from unittest.mock import patch; "
            "sys.argv=sys.argv[1:]; "
            "p=patch.object(os,'fchmod',side_effect=OSError('injected')); p.start(); "
            "runpy.run_path(sys.argv[0],run_name='__main__')"
        )
        result = subprocess.run(["python3", "-c", program, str(SCRIPT), str(self.source), str(self.output)], capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


class BuildReproducedWriterTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("SNES_ZIG_BINARY"), "requires the pinned Zig toolchain")
    def test_builds_pinned_research_writer_without_authorizing_firmware(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "new-build"
            command = ["python3", str(BUILD_SCRIPT), str(output), os.environ["SNES_ZIG_BINARY"]]
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
            self.assertEqual(hashlib.sha256((output / "bounded-nand-write").read_bytes()).hexdigest(), EXPECTED)
            record = json.loads((output / "build.json").read_bytes())
            self.assertFalse(record["firmwareWriteAuthorized"])
            self.assertFalse(record["hardwareTested"])
            self.assertFalse(record["sourceProvenanceVerified"])
            before = (output / "build.json").read_bytes()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual((output / "build.json").read_bytes(), before)

    def test_failed_toolchain_leaves_no_published_writer(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "new-build"
            command = ["python3", str(BUILD_SCRIPT), str(output), "/usr/bin/false"]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertFalse(output.exists())

    def test_existing_destination_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "existing"
            output.mkdir()
            (output / "keep").write_bytes(b"untouched")
            command = ["python3", str(BUILD_SCRIPT), str(output), "/usr/bin/false"]
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual((output / "keep").read_bytes(), b"untouched")


class InvalidWriterTests(unittest.TestCase):
    def test_invalid_input_is_rejected_without_a_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, output = root / "input", root / "output"
            source.write_bytes(b"not an ELF")
            result = subprocess.run(["python3", str(SCRIPT), str(source), str(output)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
