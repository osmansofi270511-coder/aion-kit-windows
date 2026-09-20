"""Regression guards for the UTF-8 trap that makes aion-kit's probes lie on Windows.

The trap: `subprocess.run(..., text=True)` with no `encoding=` decodes the
child's output with the *locale* encoding. On Windows that is a legacy code
page, never UTF-8. A child that prints non-ASCII then produces either mojibake
or UnicodeDecodeError, and the caller concludes the child failed when it did
not.

These tests do not describe the trap. They fail on code that has it and pass
on code that does not.

Run:  python -m unittest discover -s tests -v
"""
import subprocess
import sys
import unittest

# Deliberately non-ASCII, and deliberately not Latin-1 representable:
# characters that no single-byte Windows code page can round-trip.
SAMPLE = "ворота: ДА — проба сошлась"

# A child that writes raw UTF-8 bytes. Writing bytes rather than using print()
# keeps the child's own stdout encoding out of the experiment: whatever the
# console code page is, these exact bytes come out.
CHILD = (
    "import sys; "
    "sys.stdout.buffer.write({!r}.encode('utf-8')); "
    "sys.stdout.buffer.flush()"
).format(SAMPLE)


def run_child(**kwargs):
    return subprocess.run([sys.executable, "-c", CHILD],
                          capture_output=True, **kwargs)


class ExplicitEncodingWorks(unittest.TestCase):
    """The fix: name the encoding and the text survives."""

    def test_roundtrip_is_exact(self):
        result = run_child(text=True, encoding="utf-8")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, SAMPLE)

    def test_bytes_mode_is_also_safe(self):
        """Not decoding at all is the other correct answer."""
        result = run_child()
        self.assertEqual(result.stdout.decode("utf-8"), SAMPLE)

    def test_errors_replace_never_raises(self):
        """A caller that cannot be sure of the child's encoding still must not crash."""
        result = run_child(text=True, encoding="utf-8", errors="replace")
        self.assertEqual(result.stdout, SAMPLE)


class TheTrapIsReal(unittest.TestCase):
    """Decoding UTF-8 bytes as a legacy code page loses the text.

    Done in memory so the result does not depend on which code page the
    runner happens to have.
    """

    def test_legacy_codepage_mangles_or_raises(self):
        raw = SAMPLE.encode("utf-8")

        with self.assertRaises(UnicodeDecodeError):
            raw.decode("cp1252")

        # cp866 does not raise, which is worse: the failure is silent.
        self.assertNotEqual(raw.decode("cp866"), SAMPLE)


class PlatformFacts(unittest.TestCase):
    """Facts about Windows that aion-kit's Unix parts depend on."""

    @unittest.skipUnless(sys.platform == "win32", "Windows-only fact")
    def test_af_unix_is_absent_on_windows(self):
        """The socket door cannot open natively. Stated as a test so it is
        checked rather than remembered; if CPython ever ships AF_UNIX on
        Windows, this fails and the README needs rewriting."""
        import socket
        self.assertFalse(hasattr(socket, "AF_UNIX"))

    @unittest.skipUnless(sys.platform == "win32", "Windows-only fact")
    def test_fcntl_is_absent_on_windows(self):
        with self.assertRaises(ImportError):
            import fcntl  # noqa: F401


if __name__ == "__main__":
    unittest.main()
