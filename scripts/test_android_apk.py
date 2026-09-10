"""Offline regression tests for rejecting incorrectly packaged native code."""
import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import warnings
import zipfile

SCRIPT = Path(__file__).with_name("verify_android_apk.py")
SPEC = importlib.util.spec_from_file_location("verify_android_apk", SCRIPT)
VERIFY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFY)


def elf(bits=1, machine=40, kind=3):
    header = bytearray(64)
    header[:6] = b"\x7fELF" + bytes([bits, 1])
    struct.pack_into("<HH", header, 16, kind, machine)
    return header


class ApkNativeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.apk = Path(self.tmp.name) / "fixture.apk"

    def write(self, abis=("armeabi-v7a",), missing=None, corrupt=None, extra=None):
        with zipfile.ZipFile(self.apk, "w") as archive:
            for abi in abis:
                for lib in VERIFY.REQUIRED - set(missing or []):
                    payload = elf(*VERIFY.MACHINES[abi])
                    if lib == "libwatchit_core.so" and corrupt is not None:
                        payload = corrupt
                    archive.writestr(f"lib/{abi}/{lib}", payload)
            if extra:
                archive.writestr(*extra)

    def test_complete_32_and_64_bit_sets(self):
        for abis in [("armeabi-v7a",), ("arm64-v8a",), ("armeabi-v7a", "arm64-v8a")]:
            with self.subTest(abis=abis):
                self.write(abis)
                self.assertEqual(set(VERIFY.inspect_native(self.apk, abis)), set(abis))

    def test_missing_client_refused(self):
        self.write(missing=["libwatchit_core.so"])
        with self.assertRaisesRegex(ValueError, "missing"):
            VERIFY.inspect_native(self.apk, ["armeabi-v7a"])

    def test_arm64_hidden_under_armv7_refused(self):
        self.write(corrupt=elf(2, 183))
        with self.assertRaisesRegex(ValueError, "Wrong ELF"):
            VERIFY.inspect_native(self.apk, ["armeabi-v7a"])

    def test_stale_other_abi_refused(self):
        self.write(extra=("lib/arm64-v8a/libmpv.so", elf(2, 183)))
        with self.assertRaisesRegex(ValueError, "Unexpected native"):
            VERIFY.inspect_native(self.apk, ["armeabi-v7a"])

    def test_missing_entire_selected_abi_refused(self):
        self.write()
        with self.assertRaisesRegex(ValueError, "ABI set"):
            VERIFY.inspect_native(self.apk, ["armeabi-v7a", "arm64-v8a"])

    def test_truncated_or_non_library_elf_refused(self):
        for payload in (b"\x7fELF", elf(kind=2), b"x" * 64):
            with self.subTest(payload=payload[:6]):
                self.write(corrupt=payload)
                with self.assertRaisesRegex(ValueError, "Wrong ELF"):
                    VERIFY.inspect_native(self.apk, ["armeabi-v7a"])

    def test_duplicate_member_refused(self):
        self.write()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.apk, "a") as archive:
                archive.writestr("lib/armeabi-v7a/libwatchit_core.so", elf())
        with self.assertRaisesRegex(ValueError, "Duplicate ZIP"):
            VERIFY.inspect_native(self.apk, ["armeabi-v7a"])

    def test_invalid_build_selection_fails_before_tools(self):
        script = str(Path(__file__).with_name("build_android.sh"))
        for selection in ("x86", "", "armeabi-v7a,armeabi-v7a", "armeabi-v7a,"):
            result = subprocess.run(["bash", script, "--abis", selection],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("Unsupported or duplicate", result.stderr)

    def test_current_and_legacy_aapt2_minimum_api_fields(self):
        for field in ("minSdkVersion", "sdkVersion"):
            badging = ("package: name='io.github.aautonomicc.watchit' versionCode='95'\n"
                       f"{field}:'24'\ntargetSdkVersion:'36'\n"
                       "leanback-launchable-activity: name='example.MainActivity'\n")
            self.assertEqual(VERIFY.manifest_fields(badging, "io.github.aautonomicc.watchit"),
                             ("io.github.aautonomicc.watchit", 24))
            with self.assertRaisesRegex(ValueError, "minimum Android API"):
                VERIFY.manifest_fields(badging.replace(":'24'", ":'23'"),
                                       "io.github.aautonomicc.watchit")


if __name__ == "__main__":
    unittest.main()
