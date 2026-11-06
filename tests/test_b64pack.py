import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "b64pack.py"


def run(cwd, *args):
    return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=cwd, capture_output=True, text=True)


class B64PackTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def write(self, relative, content):
        path = self.tmp / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content if isinstance(content, bytes) else content.encode())
        return path

    def java_project(self):
        self.write("biblioteca/pom.xml", "<project/>")
        self.write("biblioteca/src/main/java/com/acme/build/Builder.java", "class Builder {}")
        self.write("biblioteca/target/classes/com/acme/App.class", b"\xca\xfe\xba\xbe")
        self.write("biblioteca/.git/config", "[core]")
        self.write("biblioteca/.idea/workspace.xml", "<x/>")
        self.write("biblioteca/.DS_Store", b"\0")

    def test_pdf_round_trip(self):
        original = os.urandom(200_000)
        self.write("in/contratto.pdf", original)
        packed = run(self.tmp, "pack", "in/contratto.pdf")
        self.assertEqual(packed.returncode, 0, packed.stderr)
        text = (self.tmp / "contratto.zip.b64.txt").read_text()
        self.assertTrue(all(len(line) <= 76 for line in text.splitlines()))

        unpacked = run(self.tmp, "unpack", "contratto.zip.b64.txt", "-x", "out")
        self.assertEqual(unpacked.returncode, 0, unpacked.stderr)
        self.assertEqual((self.tmp / "out/contratto.pdf").read_bytes(), original)

    def test_java_project_skips_build_output_but_keeps_build_package(self):
        self.java_project()
        packed = run(self.tmp, "pack", "biblioteca")
        self.assertEqual(packed.returncode, 0, packed.stderr)
        self.assertIn("biblioteca/target/", packed.stdout)

        unpacked = run(self.tmp, "unpack", "biblioteca.zip.b64.txt", "-x", "out")
        self.assertEqual(unpacked.returncode, 0, unpacked.stderr)
        root = self.tmp / "out/biblioteca"
        self.assertTrue((root / "pom.xml").exists())
        self.assertTrue((root / "src/main/java/com/acme/build/Builder.java").exists())
        for skipped in ("target", ".git", ".idea", ".DS_Store"):
            self.assertFalse((root / skipped).exists(), skipped)

    def test_all_keeps_everything(self):
        self.java_project()
        self.assertEqual(run(self.tmp, "pack", "biblioteca", "--all").returncode, 0)
        self.assertEqual(run(self.tmp, "unpack", "biblioteca.zip.b64.txt", "-x", "out").returncode, 0)
        self.assertTrue((self.tmp / "out/biblioteca/target/classes/com/acme/App.class").exists())
        self.assertTrue((self.tmp / "out/biblioteca/.git/config").exists())

    def test_split_parts_are_found_from_one_and_missing_part_is_reported(self):
        original = os.urandom(300_000)
        self.write("big.bin", original)
        packed = run(self.tmp, "pack", "big.bin", "--split", "0.1")
        self.assertEqual(packed.returncode, 0, packed.stderr)
        parts = sorted(self.tmp.glob("big.zip.b64.part*of*.txt"))
        self.assertGreater(len(parts), 1)

        unpacked = run(self.tmp, "unpack", parts[0].name, "-x", "out")
        self.assertEqual(unpacked.returncode, 0, unpacked.stderr)
        self.assertEqual((self.tmp / "out/big.bin").read_bytes(), original)

        parts[1].unlink()
        broken = run(self.tmp, "unpack", parts[0].name, "-x", "out2")
        self.assertEqual(broken.returncode, 1)
        self.assertIn(parts[1].name, broken.stderr)

    def test_corrupted_text_is_rejected(self):
        self.write("doc.pdf", os.urandom(50_000))
        run(self.tmp, "pack", "doc.pdf")
        path = self.tmp / "doc.zip.b64.txt"
        lines = path.read_text().splitlines()
        middle = lines[len(lines) // 2]
        lines[len(lines) // 2] = ("B" if middle[10] != "B" else "C").join([middle[:10], middle[11:]])
        path.write_text("\n".join(lines) + "\n")
        result = run(self.tmp, "unpack", "doc.zip.b64.txt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("danneggiato", result.stderr)

    def test_existing_zip_is_encoded_as_is_and_text_survives_crlf(self):
        self.write("doc.pdf", b"%PDF-1.7 test")
        run(self.tmp, "pack", "doc.pdf")
        run(self.tmp, "unpack", "doc.zip.b64.txt", "-o", "doc.zip")
        original_zip = (self.tmp / "doc.zip").read_bytes()

        packed = run(self.tmp, "pack", "doc.zip", "-o", "copia")
        self.assertEqual(packed.returncode, 0, packed.stderr)
        crlf = self.tmp / "copia.zip.b64.txt"
        crlf.write_text(crlf.read_text().replace("\n", "\r\n"))
        self.assertEqual(run(self.tmp, "unpack", "copia.zip.b64.txt").returncode, 0)
        self.assertEqual((self.tmp / "copia.zip").read_bytes(), original_zip)

    def test_existing_output_needs_force(self):
        self.write("doc.pdf", b"x")
        self.assertEqual(run(self.tmp, "pack", "doc.pdf").returncode, 0)
        again = run(self.tmp, "pack", "doc.pdf")
        self.assertEqual(again.returncode, 1)
        self.assertIn("--force", again.stderr)
        self.assertEqual(run(self.tmp, "pack", "doc.pdf", "--force").returncode, 0)


if __name__ == "__main__":
    unittest.main()
