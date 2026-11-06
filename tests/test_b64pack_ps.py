"""Versione PowerShell, da sola e incrociata con quella Python. Serve pwsh nel PATH."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = ROOT / "b64pack.py"
PS = ROOT / "b64pack.ps1"
PWSH = shutil.which("pwsh")


def py(cwd, *args):
    return subprocess.run([sys.executable, str(PY), *args], cwd=cwd, capture_output=True, text=True)


def ps(cwd, *args):
    return subprocess.run([PWSH, "-NoProfile", "-NonInteractive", "-File", str(PS), *args],
                          cwd=cwd, capture_output=True, text=True)


@unittest.skipUnless(PWSH, "pwsh non installato")
class PowerShellTest(unittest.TestCase):
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

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_ps_text_has_the_same_format(self):
        self.write("doc.pdf", os.urandom(20_000))
        self.ok(ps(self.tmp, "pack", "doc.pdf"))
        raw = (self.tmp / "doc.zip.b64.txt").read_bytes()
        self.assertNotIn(b"\r", raw)
        self.assertTrue(raw.endswith(b"\n"))
        self.assertFalse(raw.startswith(b"\xef\xbb\xbf"))
        lines = raw.decode("ascii").splitlines()
        self.assertTrue(all(len(line) == 76 for line in lines[:-1]))

    def test_ps_pack_python_unpack_java_project(self):
        self.java_project()
        packed = self.ok(ps(self.tmp, "pack", "biblioteca"))
        self.assertIn("biblioteca/target/", packed.stdout)
        self.assertIn("1 file (.class, .DS_Store)", packed.stdout)
        self.ok(py(self.tmp, "unpack", "biblioteca.zip.b64.txt", "-x", "out"))
        root = self.tmp / "out/biblioteca"
        self.assertTrue((root / "src/main/java/com/acme/build/Builder.java").exists())
        for skipped in ("target", ".git", ".idea", ".DS_Store"):
            self.assertFalse((root / skipped).exists(), skipped)

    def test_python_split_ps_unpack_from_one_part(self):
        original = os.urandom(300_000)
        self.write("big.bin", original)
        self.ok(py(self.tmp, "pack", "big.bin", "--split", "0.1"))
        first = sorted(self.tmp.glob("big.zip.b64.part*of*.txt"))[0]
        self.ok(ps(self.tmp, "unpack", first.name, "-x", "out"))
        self.assertEqual((self.tmp / "out/big.bin").read_bytes(), original)

    def test_ps_split_python_unpack_and_missing_part(self):
        original = os.urandom(300_000)
        self.write("big.bin", original)
        self.ok(ps(self.tmp, "pack", "big.bin", "-Split", "0.1"))
        parts = sorted(self.tmp.glob("big.zip.b64.part*of*.txt"))
        self.assertGreater(len(parts), 1)
        self.ok(py(self.tmp, "unpack", parts[-1].name, "-x", "out"))
        self.assertEqual((self.tmp / "out/big.bin").read_bytes(), original)

        parts[1].unlink()
        broken = ps(self.tmp, "unpack", parts[0].name, "-x", "out2")
        self.assertEqual(broken.returncode, 1)
        self.assertIn(parts[1].name, broken.stderr)

    def test_ps_detects_corruption_through_crc(self):
        self.write("doc.pdf", os.urandom(50_000))
        self.ok(py(self.tmp, "pack", "doc.pdf"))
        path = self.tmp / "doc.zip.b64.txt"
        lines = path.read_text().splitlines()
        middle = lines[len(lines) // 2]
        lines[len(lines) // 2] = middle[:10] + ("B" if middle[10] != "B" else "C") + middle[11:]
        path.write_text("\n".join(lines) + "\n")
        result = ps(self.tmp, "unpack", "doc.zip.b64.txt")
        self.assertEqual(result.returncode, 1)
        self.assertIn("danneggiato", result.stderr)

    def test_utf16_text_from_windows_powershell_is_read_by_both(self):
        original = os.urandom(10_000)
        self.write("doc.pdf", original)
        self.ok(ps(self.tmp, "pack", "doc.pdf", "-o", "copia"))
        text = (self.tmp / "copia.zip.b64.txt").read_text()
        (self.tmp / "utf16.txt").write_bytes(b"\xff\xfe" + text.replace("\n", "\r\n").encode("utf-16-le"))
        self.ok(ps(self.tmp, "unpack", "utf16.txt", "-x", "ps"))
        self.ok(py(self.tmp, "unpack", "utf16.txt", "-x", "py"))
        self.assertEqual((self.tmp / "ps/doc.pdf").read_bytes(), original)
        self.assertEqual((self.tmp / "py/doc.pdf").read_bytes(), original)

    def test_several_inputs_existing_zip_and_force(self):
        self.write("a.pdf", b"%PDF a")
        self.write("b.pdf", b"%PDF b")
        self.ok(ps(self.tmp, "pack", "a.pdf", "b.pdf"))
        self.ok(ps(self.tmp, "unpack", "archivio.zip.b64.txt"))
        again = ps(self.tmp, "pack", "a.pdf", "b.pdf")
        self.assertEqual(again.returncode, 1)
        self.assertIn("-Force", again.stderr)

        zipped = self.ok(ps(self.tmp, "pack", "archivio.zip", "-o", "riuso"))
        self.assertIn("gia' uno zip", zipped.stdout)
        self.ok(py(self.tmp, "unpack", "riuso.zip.b64.txt"))
        self.assertEqual((self.tmp / "riuso.zip").read_bytes(), (self.tmp / "archivio.zip").read_bytes())

    def test_unknown_option_is_reported(self):
        self.write("doc.pdf", b"x")
        result = ps(self.tmp, "pack", "doc.pdf", "-Comprimi")
        self.assertEqual(result.returncode, 1)
        self.assertIn("parametro sconosciuto", result.stderr)

    def test_no_arguments_prints_usage(self):
        result = ps(self.tmp)
        self.assertEqual(result.returncode, 1)
        self.assertIn("uso:", result.stdout)


if __name__ == "__main__":
    unittest.main()
