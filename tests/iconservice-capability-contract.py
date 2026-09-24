#!/usr/bin/env python3
"""Portable source contracts; these do not simulate Apple's private APIs."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / name).read_text()


class CapabilityContracts(unittest.TestCase):
    def test_store_does_not_validate_image_construction(self):
        store = source("iconservice/MTIconServiceStoreInvalidator.m")
        self.assertIn("MTIconServiceABIValidateProcess(&ABIError)", store)
        self.assertNotIn("MTIconServiceABIValidateRuntime(", store)
        abi = source("iconservice/MTIconServiceABI.m")
        process = abi.split("BOOL MTIconServiceABIValidateProcess(", 1)[1].split(
            "BOOL MTIconServiceABIValidateRuntime(", 1)[0]
        for required in ("processName", "MTIconServiceExecutablePath()",
                         'getenv("XPC_SERVICE_NAME")', "if (!identityMatches)"):
            self.assertIn(required, process)
        for unrelated in ("IFCacheImage", "MTValidated", "MTIconServiceMethodMatches"):
            self.assertNotIn(unrelated, process)

    def test_generation_still_requires_serializer_and_rehydrator(self):
        abi = source("iconservice/MTIconServiceABI.m")
        for required in (
            "!MTIconServiceABIValidateProcess(error)",
            "cacheInitializer, MTCacheImageInitializerTypeEncoding",
            "dataInitializer, MTImageDataInitializerTypeEncoding",
            "strcmp(actual, encoding) == 0", "implementation != NULL",
            "dladdr((const void *)implementation, &info)",
            "isEqualToString:imagePath",
        ):
            self.assertIn(required, abi)
        construct = abi.split("id MTIconServiceABICreateReplacementImage(", 1)[1]
        self.assertIn("cacheImageClass == Nil || cacheMethod == NULL ||", construct)
        self.assertIn("imageClass == Nil || dataMethod == NULL", construct)
        self.assertLess(construct.index("id temporary ="), construct.index("id bitmapData ="))
        self.assertLess(construct.index("id bitmapData ="), construct.index("id replacement ="))
        self.assertIn("bitmapData, originalUUID, validationToken", construct)

    def test_native_clear_checks_and_completion_remain(self):
        store = source("iconservice/MTIconServiceStoreInvalidator.m")
        for required in (
            'MTClearOperationRunTypeEncoding = "v16@0:8"',
            'MTClearOperationTypeTypeEncoding = "Q16@0:8"',
            'MTClearOperationCacheTypeEncoding = "@16@0:8"',
            "MTWholeCacheOperationType = 2", "MTWholeCacheOperationTimeout = 4.0",
            "if (returnedNormally && operation == MTWholeCacheOperationType &&",
            "if (self.pendingWholeStoreCache == cache)",
            'outcome:@"native-clear-completion-timeout"',
        ):
            self.assertIn(required, store)
        hook = store.split("static void MTIconServiceHookedClearOperationRun(", 1)[1]
        self.assertLess(hook.index("MTOriginalClearOperationRun(self, selector);"),
                        hook.index("returnedNormally = YES;"))
        self.assertEqual(store.count("finishWithVerified:YES"), 1)

    def test_acknowledgement_still_requires_verification(self):
        bootstrap = source("iconservice/MTIconServiceBootstrap.m")
        callback = bootstrap.split("^(MTIconServiceStoreInvalidationResult *result)", 1)[1]
        verified, failure = callback.split("if (result.isVerified) {", 1)[1].split("} else {", 1)
        self.assertIn("MTIconServicePostAcknowledgement(sequence)", verified)
        self.assertNotIn("MTIconServicePostAcknowledgement", failure)
        self.assertIn("if (!atomic_load_explicit(", bootstrap)
        self.assertIn("runtimeResult.iconServiceAcknowledged", source("workflow/MTThemeApplyService.m"))

    def test_probe_is_focused_and_read_only(self):
        probe = source("tools/iconservice-abi-probe/Probe.m")
        self.assertIn("MTIconServiceImageConstructionDiagnosticReport()", probe)
        self.assertNotIn("MTIconServiceABIDiagnosticReport(nil)", probe)
        for forbidden in ("MSHookMessageEx", "objc_msgSend", "PostAcknowledgement",
                          "PublishRuntimeStatus", "scheduleCacheOperation"):
            self.assertNotIn(forbidden, probe)
        diagnostics = source("iconservice/MTIconServiceABIDiagnostics.m")
        focused = diagnostics.split("MTIconServiceImageConstructionDiagnosticReport(void)", 1)[1].split(
            "MTIconServiceABIDiagnosticReport(NSError", 1)[0]
        self.assertNotIn("ClearCacheOperation", focused)
        self.assertNotIn("objc_copyClassList", focused)

    def test_only_obsolete_linker_option_is_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            makefiles = pathlib.Path(directory) / "makefiles"
            makefiles.mkdir()
            fixture = makefiles / "test.mk"
            fixture.write_text("FLAGS = -Wl,-fatal_warnings -Wl,-multiply_defined,suppress -O2\n"
                               "FLAGS += -multiply_defined suppress -fatal_warnings\n")
            subprocess.run([sys.executable, str(ROOT / "scripts/ci-remove-obsolete-theos-flag"),
                            directory], check=True, capture_output=True)
            self.assertEqual(fixture.read_text(),
                             "FLAGS = -Wl,-fatal_warnings  -O2\nFLAGS +=  -fatal_warnings\n")


if __name__ == "__main__":
    unittest.main()
