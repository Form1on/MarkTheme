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
            "MTCacheImageInitializerTypeEncoding, expectedImage",
            "MTImageDataInitializerTypeEncoding, expectedImage",
            "strcmp(actual, encoding) == 0", "implementation != NULL",
            "dladdr((const void *)implementation, &info)",
            "isEqualToString:imagePath",
        ):
            self.assertIn(required, abi)
        construct = abi.split("static id MTIconServiceCreateReplacementImage(", 1)[1]
        self.assertIn("construction.path == MTIconServiceImageConstructionUnavailable", construct)
        self.assertIn("imageClass == Nil || dataMethod == NULL", construct)
        self.assertLess(construct.index("id temporary ="), construct.index("id bitmapData ="))
        self.assertLess(construct.index("id bitmapData ="), construct.index("id replacement ="))
        self.assertLess(construct.index("((MTSizeSetterFunction)"), construct.index("id bitmapData ="))
        self.assertIn("__attribute__((ns_consumed)) id,\n    SEL, CGImageRef, double, CGSize, BOOL)", abi)
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
        verified = callback.split("if (result.isVerified) {", 1)[1].split(
            "MTIconServiceRuntimeStageTransactionFailed", 1)[0]
        self.assertIn("MTIconServiceFinishVerifiedCycle(", verified)
        self.assertIn("MTIconServiceApplyEvidenceSatisfied(true, requestsApplicationIcons,", bootstrap)
        self.assertLess(bootstrap.index("if (!MTIconServiceApplyEvidenceSatisfied("),
                        bootstrap.index("MTIconServicePostAcknowledgement(sequence);"))
        self.assertIn("MTIconServiceRuntimeStageGenerationNotObserved", bootstrap)
        self.assertIn("MTIconServiceRuntimeStageReplacementNotProduced", bootstrap)
        self.assertIn("MTIconServiceGenerationAdapterCycleReplacements(sequence)", bootstrap)
        self.assertIn("if (result.isVerified)", bootstrap)
        self.assertIn("if (!atomic_load_explicit(", bootstrap)
        self.assertIn("runtimeResult.iconServiceAcknowledged", source("workflow/MTThemeApplyService.m"))

    def test_execution_telemetry_is_bound_to_live_daemon(self):
        adapter = source("iconservice/MTIconServiceGenerationAdapter.m")
        transport = source("runtime/MTRuntimeInvalidation.m")
        helper = source("helper/main.m")
        for name in ("generationAdapterInstalled", "generationHookCallCount",
                     "resolverCallCount", "themedResolverMatchCount",
                     "replacementCGImageCount", "replacementIFImageCount",
                     "replacementReturnedCount", "passthroughCount",
                     "constructionFailureCount", "selectedImageConstructionPath",
                     "lastBundleIdentifier"):
            self.assertIn(name, adapter)
            self.assertIn(name, transport)
        self.assertIn("generationIdentifierOut:&resolvedGenerationIdentifier", adapter)
        self.assertIn("MTActiveCycleGenerationIdentifier", adapter)
        self.assertIn("MTIconServiceReadExecutionTelemetry(status)", helper)
        self.assertIn("MTIconServiceRuntimeStatusIsCurrentAndLive(status)", transport)
        self.assertIn("start == end", transport)
        self.assertIn("telemetryAvailable", transport)

    def test_compiled_execution_counters_and_apply_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = str(pathlib.Path(directory) / "execution")
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-pthread", "-I", str(ROOT / "iconservice"),
                            str(ROOT / "tests/MTIconServiceExecutionTests.c"),
                            "-o", binary], check=True)
            subprocess.run([binary], check=True)

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

    def test_compiled_construction_policy(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = str(pathlib.Path(directory) / "construction-policy")
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-I", str(ROOT / "iconservice"),
                            str(ROOT / "tests/MTIconServiceImageConstructionPolicyTests.c"),
                            "-o", binary], check=True)
            subprocess.run([binary], check=True)

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
