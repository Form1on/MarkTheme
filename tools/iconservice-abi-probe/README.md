# MarkTheme IconServices ABI diagnostic patch

Base commit: `53bc9b36e773b42bc61b61ccebfe04c129ff58b6` (v0.3.1, Runtime 204).
This is the requested diagnostic-first fallback. No iOS 18.1.1 compatibility
claim or new accepted ABI is included; those require the real device report.

## What detail 3 means

The status protocol publishes only `NSError.code`, not its domain. The
`installWithError:` path can return either of these errors:

| NSError domain | Meaning of code 3 |
| --- | --- |
| `com.hmmzzz.marktheme.icon-service-abi` | Earlier generation/image constructor validation failed: required class, encoding, or implementation image. |
| `com.hmmzzz.marktheme.icon-service-store-invalidator` | At least one ClearCacheOperation instance method failed exact encoding/IMP image validation. |

The second error requires these methods:

| Instance method | Expected encoding |
| --- | --- |
| `run` | `v16@0:8` |
| `operation` | `Q16@0:8` |
| `cache` | `@16@0:8` |

Each IMP must resolve through `dladdr()` to
`/System/Library/CoreServices/iconservicesagent`. A missing method, changed
encoding, moved/inherited implementation, or an existing replacement Hook can
all fail. The supplied status cannot identify which condition failed.

The source contains no captured iOS 18.1.1 ABI establishing a compatibility
adapter. A different selector cannot safely be substituted based only on its
name and type encoding; its native transaction semantics also need evidence.

## Exact behavior change

- Previously, startup logged error domain/code and published a numeric detail.
- The integrated patch preserves the rejection and adds per-method diagnostics:
  expected/actual type encodings, instance/class distinction, missing classes
  and selectors, IMP addresses/images, OS version, PID and Runtime build.
  It retains the actual NSError domain/description at the failure site.
- The standalone probe loads only in `iconservicesagent`. It captures metadata
  at startup and once two seconds later, without hooking or invoking private
  cache methods. It writes only its own temporary JSON reports and logs.
- Existing ABI acceptance, type-2 native operation, normal-return verification,
  pending-cache identity, timeout, `result.isVerified`, and helper/UI
  acknowledgement gates are unchanged.
- The existing same-generation shortcut still reuses a transaction previously
  verified for that generation in the same process; no new shortcut is added.

The source patch increments Runtime 204 to 205. The separate probe does not
replace MarkTheme: `compiledRuntimeBuild` labels its source, whereas
`observedRuntimeStatus.runtimeBuild` records the installed Runtime's published
build. Only `belongsToThisProcess: true` associates that state with this PID.
The standalone capture may occur after another tweak has installed a Hook;
an IMP in a tweak's image must be interpreted in that context. It is explicitly
marked as not being at the original validation failure site.

## Apply the source patch

From a clean checkout of the base commit, with the downloaded patch one level
above the repository:

```sh
git switch -c iconservice-abi-diagnostics 53bc9b36e773b42bc61b61ccebfe04c129ff58b6
git apply --check ../marktheme-abi-diagnostics.patch
git apply ../marktheme-abi-diagnostics.patch
```

## Build without owning a Mac

The patch includes a manual GitHub Actions workflow using a macOS runner.
It has not been run by this assistant, and no upstream changes were pushed.

1. Fork MarkTheme into your GitHub account and apply this patch to your fork's
   default branch (or merge your diagnostics branch into that branch).
2. Commit and push the patch, including `.github/workflows/iconservice-abi-probe.yml`.
3. In the fork, open **Actions → Build IconServices ABI probe → Run workflow**.
4. After a successful run, download the `MarkTheme-ABI-probe-rootless` artifact
   and extract the `.deb` from it. A failed run does not yield a usable package.

The workflow builds only the standalone probe, with read-only repository
permissions. It does not publish a release, connect to your phone, or Apply a
theme. Actions and Theos revisions are pinned in the workflow.

## Local macOS build

Requires Xcode, Theos, an iOS SDK and `ldid`, with the modern arm64e ABI:

```sh
export THEOS=/absolute/path/to/theos
make -C tools/iconservice-abi-probe clean
make -C tools/iconservice-abi-probe package THEOS_PACKAGE_SCHEME=rootless
```

Expected output **only after a successful build**:

```text
tools/iconservice-abi-probe/packages/com.hmmzzz.marktheme.abiprobe_0.1.0_iphoneos-arm64.deb
```

The Debian architecture is `iphoneos-arm64`, and the dylib includes `arm64`
and `arm64e`. The A13 system daemon needs the modern arm64e slice. Do not
remove `-fatal_warnings` to suppress an incompatible-arm64e linker warning.

## Install and collect on the iPhone

Transfer the built file from the computer (replace `IPHONE_IP`):

```sh
scp com.hmmzzz.marktheme.abiprobe_0.1.0_iphoneos-arm64.deb mobile@IPHONE_IP:/var/mobile/
ssh mobile@IPHONE_IP
```

Run in the phone's SSH shell:

```sh
sudo dpkg -i /var/mobile/com.hmmzzz.marktheme.abiprobe_0.1.0_iphoneos-arm64.deb
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
sleep 3
sudo /var/jb/usr/libexec/marktheme-helper status --json
sudo find /private/var -name marktheme-iconservices-abi.json -type f -exec cat {} \; > /var/mobile/marktheme-abi-report.txt
wc -c /var/mobile/marktheme-abi-report.txt
```

The service restart loads the probe. No theme Apply is needed for metadata.
Each capture uses a fresh private temporary directory and an exclusive 0600
file. The collected text can contain multiple JSON documents; each has a PID,
timestamp and capture phase. From the computer, retrieve it:

```sh
scp mobile@IPHONE_IP:/var/mobile/marktheme-abi-report.txt .
```

Send that file and the helper status output. A zero-length file is not success:
the probe may not have loaded, or the sandbox may have denied its report write.
If Apple's `/usr/bin/log` is available on the phone, capture the fallback:

```sh
sudo /usr/bin/log show --last 5m --style compact --predicate 'process == "iconservicesagent" AND (subsystem == "com.hmmzzz.marktheme" OR eventMessage CONTAINS "MarkTheme ABI probe")'
```

Otherwise use macOS Console with the phone connected over USB, filtering for
`iconservicesagent` and `MarkTheme ABI`. Temporary-file access has not been
tested on this phone's sandbox.

## Exact probe rollback

```sh
sudo dpkg -r com.hmmzzz.marktheme.abiprobe
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
```

MarkTheme 0.3.1 and its theme store/generations remain installed. Temporary
reports remain for review. The probe has no package lifecycle scripts.

## Optional integrated MarkTheme build

The separate probe is sufficient for the first capture. To build the full
diagnostic source patch, use the repository's supported macOS/Xcode and
RootHide Theos setup, while selecting conventional rootless:

```sh
export THEOS=/absolute/path/to/roothide-theos
PACKAGE_VERSION=0.3.1+abi1 ./scripts/build-packages rootless
MARKTHEME_LOCAL_TEST_ENV_READY=1 ./tests/run
```

Expected full-package path after success:
`packages/com.hmmzzz.marktheme_0.3.1+abi1_iphoneos-arm64.deb`.
Keep the original rootless release `.deb` before replacing MarkTheme.

```sh
# Phone: optional integrated diagnostics install
sudo dpkg -i /var/mobile/com.hmmzzz.marktheme_0.3.1+abi1_iphoneos-arm64.deb
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
sudo /var/jb/usr/libexec/marktheme-helper reload-desktop --json

# Phone: restore original release package
sudo dpkg -i /var/mobile/com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
sudo /var/jb/usr/libexec/marktheme-helper reload-desktop --json
```

`marktheme-helper rollback --json` rolls back a theme generation, not binaries;
it is not the package rollback command.

## Validation and outstanding work

- Objective-C syntax/type checks passed earlier in this task against an iOS
  SDK with `-Wall -Wextra -Werror` for the diagnostics, invalidator, bootstrap,
  probe and updated test source. The temporary workspace later reset; these
  source changes were restored against the same pinned base commit.
- Added diagnostic tests: the three existing ClearCacheOperation encodings,
  incompatible arguments/return encodings, wrong IMP image, missing class,
  class/instance distinction, both error-3 domains, valid JSON and no private
  method invocations. These are diagnostic tests, not native transaction tests.
- Host test execution remains blocked by missing Xcode `xcrun`. The new
  assertions are not claimed as executed. The existing Apply test rejecting
  absent IconServices acknowledgement remains unchanged.
- Production validation predicates, transaction callbacks and acknowledgement
  logic were compared with the base commit and remain unchanged.
- **No usable A13 `.deb` is supplied.** Both attempted Linux toolchains emitted
  the old arm64e ABI. The final Makefile makes that warning fatal. No package
  with that warning should be installed. The macOS workflow is provided but
  has not been executed here.
- Actual iOS 18.1.1-compatible ABI fixtures, a compatibility adapter and native
  transaction/acknowledgement regression tests await the phone's report. No
  invented compatible signature is included. Device regression checks on
  supported iOS 17/18 paths are still required before a compatibility release.

## Every changed file

| File | Change |
| --- | --- |
| `Config.mk` | Runtime build 204 → 205. |
| `iconservice/Makefile` | Link diagnostic implementation. |
| `iconservice/MTIconServiceStoreInvalidator.m` | Log installation failures, including upstream NSError domain, without changing predicates. |
| `iconservice/MTIconServiceBootstrap.m` | Include error description in log. |
| `iconservice/MTIconServiceABIDiagnostics.h` | New diagnostic declarations. |
| `iconservice/MTIconServiceABIDiagnostics.m` | New runtime metadata collection and structured logging. |
| `tests/MTIconServiceRuntimeTests.m` | Diagnostic cases. |
| `tests/run` | Link diagnostics and update build expectation. |
| `tools/iconservice-abi-probe/Makefile` | Separate rootless probe build; ABI warnings fatal. |
| `tools/iconservice-abi-probe/control` | Separate diagnostic package identity. |
| `tools/iconservice-abi-probe/MarkThemeABIProbe.plist` | Exact iconservicesagent filter. |
| `tools/iconservice-abi-probe/Probe.m` | Two bounded metadata captures and report output. |
| `tools/iconservice-abi-probe/README.md` | Findings, build/install/collection/rollback instructions and limits. |
| `.github/workflows/iconservice-abi-probe.yml` | Optional manual macOS build and artifact download. |

No changes to `helper/main.m`, `runtime/MTRuntimeInvalidation.m`,
`store/MTRuntimeHelperClient.m` or `workflow/MTThemeApplyService.m`.
