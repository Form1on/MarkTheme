# iOS 18.1.1 image-construction follow-up (build 206)

This document records the build-206 investigation. The captured constructors
are now implemented in [Runtime 207](../../docs/ICON_SERVICE_IOS18_COMPATIBILITY.md).
Use that document for the current full-package build and installation procedure.

This is a **partial validation fix, not a completed iOS 18.1.1 compatibility
release**. No supported replacement serializer has yet been observed. Apply
must still fail on the reported device. The full package workflow is prepared,
but has not been run here and no .deb is supplied.

## Exact finding

Both captures in the supplied report agree: the nine existing method checks
pass except the missing instance initializer
`IFCacheImage -initWithCGImage:scale:minimumSize:placeholder:iconSize:`.
ClearCacheOperation's run/operation/cache encodings and implementation images
pass. The error reaching store-control is code 3 from
`com.hmmzzz.marktheme.icon-service-abi`, not proof of code 3 from the
store-invalidator domain.

The call graph is:

1. Bootstrap installs store control, previously calling the global generation
   validator before checking IconCacheService/ClearCacheOperation.
2. Bootstrap installs the generation adapter, which hooks
   `ISGenerationRequest -generateImageReturningRecordIdentifiers:`.
3. The adapter calls the original method, reads its IFImage geometry, and asks
   MTIconServiceImageResolver to compose a replacement **CGImage**.
4. MTIconServiceABICreateReplacementImage constructs IFCacheImage with that
   CGImage and the original scale/minimumSize/placeholder/iconSize.
5. It obtains `bitmapData` from that temporary IFCacheImage, then calls the
   validated IFImage data initializer with those bytes, the original UUID and
   original 40-byte validation token. It restores the largest flag.

IFCacheImage and IFImage are consecutive stages, not alternative image paths.
There is no existing IFImage fallback. The proven data initializer does not
prove that it accepts PNG, arbitrary raw pixels, or a CGImage object. Its
Objective-C encoding only says that its three explicit arguments are objects.

**Missing runtime fact:** the supported iOS 18.1.1 constructor/serialization
path that produces IFImage-compatible bitmapData from a replacement CGImage
while preserving the required geometry; alternatively, evidence of a direct
image constructor with equivalent semantics. Neither the source nor the
supplied report establishes that path. This is the explicit stop condition
allowed in the task. No speculative selector, data format, or OR gate is added.

## Changes and exact behavior

- Extract the unchanged process name/executable/XPC-service identity checks
  into MTIconServiceABIValidateProcess.
- Store control calls that process validator and keeps all its existing exact
  method/encoding/IMP-image checks. It no longer depends on image construction.
- Generation validation still requires both construction stages. Each failed
  stage now names its own requirement, retaining error code 3.
- Generation installation emits focused image diagnostics. It does not report
  already-hooked ClearCacheOperation IMPs as the cause of a generation failure.
- Diagnostics report `imageConstruction.selectedPath` as
  `legacy-cache-image-bitmap-data` only when both constructor checks pass;
  otherwise `unavailable`. This describes constructor metadata, not verified
  execution, runtime readiness, or an acknowledgement.
- Build number is 206. Legacy construction and its exact acceptance predicates
  remain intact. Unknown construction ABIs still fail.
- The probe is version 0.2.0 and captures only IFCacheImage/IFImage hierarchies,
  with declared instance/class methods, exact encodings, IMP addresses/images,
  class images, OS version, PID and compiled build. Candidates are never called.
  Ancestor declarations are included, stopping before NSObject.

Before: missing IFCacheImage initializer surfaces as
`store-control-failed/detail=3`.

After, **if store-hook installation succeeds**: the generation adapter rejects
the unsupported serializer and surfaces as
`generation-adapter-failed/detail=4`, with underlying generation ABI code 3.
This is a correctly attributed failure, not successful Apply.

Native type-2 whole-cache scheduling, normal-return detection, pending-cache
identity, timeout handling, result.isVerified, helper/UI acknowledgement gates,
and the existing same-generation reuse of a previously verified transaction
are unchanged. No acknowledgement is possible merely because store hooks install.

## Apply this incremental patch

The delivered patch is relative to the attached diagnostic work, preserved as
local baseline commit `e88a8b6`. The working checkout available here was
`/workspace/scratch/257fe7d9a567/MarkTheme`; `~/marktheme-src` was not mounted.
No upstream commits were reset or pushed.

In your existing checkout, after placing the patch in your home directory:

```sh
cd ~/marktheme-src
git apply --check ~/marktheme-capability-scope.patch
git apply ~/marktheme-capability-scope.patch
git add .gitignore .github/workflows Config.mk iconservice tests/run \
  tests/MTIconServiceRuntimeTests.m tests/iconservice-capability-contract.py \
  scripts/ci-remove-obsolete-theos-flag tools/iconservice-abi-probe
git commit -m "fix(iconservice): scope store validation and isolate missing serializer"
```

If your already-corrected workflow differs, git apply --check may report a
conflict. Preserve those existing fixes and integrate the equivalent workflow
changes; do not reset your checkout.

## Focused capture without a Mac

Push the changes to your fork. If the manual workflow is new, it must exist on
the fork's default branch to appear in Actions; select your work branch when
running it.

Workflow file: `.github/workflows/iconservice-abi-probe.yml`
Workflow: **Build IconServices image construction probe**
Artifact: **MarkTheme-image-construction-probe-rootless**

After CI succeeds, its package is:

`com.hmmzzz.marktheme.abiprobe_0.2.0_iphoneos-arm64.deb`

On the computer:

```sh
scp com.hmmzzz.marktheme.abiprobe_0.2.0_iphoneos-arm64.deb mobile@172.20.10.2:/var/mobile/
ssh mobile@172.20.10.2
```

On the phone:

```sh
sudo dpkg -i /var/mobile/com.hmmzzz.marktheme.abiprobe_0.2.0_iphoneos-arm64.deb
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
sleep 3
sudo find /private/var -name marktheme-image-construction.json -type f -exec cat {} \; > /var/mobile/marktheme-image-construction-report.txt
wc -c /var/mobile/marktheme-image-construction-report.txt
```

Retrieve from the computer:

```sh
scp mobile@172.20.10.2:/var/mobile/marktheme-image-construction-report.txt .
```

Send only this focused report. It contains constructor-time and after-startup
JSON captures. No Apply or repeat broad store-control capture is needed.
A zero-byte report is not a successful capture. Metadata is also emitted in
short unified-log records under subsystem com.hmmzzz.marktheme,
category icon-service-abi.

Remove the probe and restart its host:

```sh
sudo dpkg -r com.hmmzzz.marktheme.abiprobe
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
```

This removes the probe package (including an older version it replaced),
leaving MarkTheme installed.

## Complete conventional-rootless package CI (not a compatibility release)

Workflow file: `.github/workflows/marktheme-rootless.yml`
Workflow: **Build full MarkTheme rootless package**
Artifact: **MarkTheme-full-rootless-build206-unverified**

It builds app, helper, display runtime and IconServices runtime using Xcode
and RootHide Theos pinned to
`88506b2c22e9e07dd4ed055f23c9e398a117a2c7`, including its pinned submodules.
The full build needs the fork's roothide.h/rootless stub; the probe can use
upstream Theos because it does not use MarkTheme's path layer.

Both workflows use github.workspace for THEOS, remove only the obsolete
multiply_defined suppress option, preserve fatal linker warnings and use
`xcrun lipo <binary> -verify_arch arm64 arm64e`.
The full workflow checks all four staged binaries and runs the existing
package audit. The artifact includes a toolchain manifest and SHA256SUMS.

The exact **expected** full-package output after successful CI is:

`packages/com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb`

It is not an existing built artifact. Its Debian architecture is iphoneos-arm64;
its binaries are configured for both arm64 and arm64e. Version stays 0.3.1 to
satisfy the existing pinned release audit; the runtime build is 206. The artifact
name and compatibility note distinguish it from the original release.

Equivalent build command on a prepared macOS/Xcode runner:

```sh
export THEOS=/absolute/path/to/roothide-theos
python3 scripts/ci-remove-obsolete-theos-flag "$THEOS"
MARKTHEME_LOCAL_TEST_ENV_READY=1 ./tests/run
FINALPACKAGE=1 ADDITIONAL_LDFLAGS=-Wl,-fatal_warnings ./scripts/build-packages rootless
```

No full-package installation is needed to collect the focused report.
If testing this partial build, first retain the **original** rootless 0.3.1
release package separately as `/var/mobile/marktheme-rollback-0.3.1.deb`.
Do not overwrite that backup with the identically versioned CI package.

Transfer the CI package to /var/mobile, then run:

```sh
sudo /var/jb/usr/libexec/marktheme-helper status --json
sudo dpkg -i /var/mobile/com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
sudo /var/jb/usr/libexec/marktheme-helper reload-desktop --json
sudo /var/jb/usr/libexec/marktheme-helper status --json
```

Reopen MarkTheme and tap Apply for the theme, then:

```sh
sudo /var/jb/usr/libexec/marktheme-helper status --json
```

On the reported ABI, failure is still expected. A cache-control stage change
alone does not establish compatibility.

Restore the original package (without purging theme data):

```sh
sudo dpkg -i /var/mobile/marktheme-rollback-0.3.1.deb
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
sudo /var/jb/usr/libexec/marktheme-helper reload-desktop --json
sudo /var/jb/usr/libexec/marktheme-helper status --json
```

Helper rollback changes theme generations; it does not restore package binaries.

## Validation

Passed locally:
- Six portable source-contract tests, including independent store validation,
  required serializer/rehydrator stages, native transaction safeguards,
  acknowledgement guard, focused probe scope and narrowly removed linker flag.
- Existing package lifecycle contract test.
- Shell/workflow run-step syntax, workflow YAML and plist parsing, git diff check.
- Exact comparison with the preserved diagnostics baseline: process identity
  predicate, private replacement construction, all store transaction code,
  bootstrap, helper, runtime invalidation, helper client and Apply service
  remain unchanged except the explicit store validation call replacement.
- The linker-option script was exercised against the pinned RootHide Theos;
  only its darwin_tail.mk obsolete option changed.

Added macOS host assertions for the two exact legacy constructor encodings,
focused capture scope and constructor capability reporting. Existing tests for
wrong encodings, wrong IMP images, absent methods/classes and class/instance
distinction remain.

Not run: Objective-C compilation/host execution and full package build
(`xcrun` unavailable); generated profile check (Ruby unavailable).
Both macOS workflows include the required native tooling, but neither workflow
was triggered here. The portable checks are source contracts, not simulated
native transaction tests.

The requested accepted iOS 18.1.1 adapter case and end-to-end native transaction
tests cannot honestly be added as passing tests until a supported serializer
is established. No fabricated compatible fixture is included.

## Files changed relative to the preserved diagnostics work

- `iconservice/MTIconServiceABI.h`
- `iconservice/MTIconServiceABI.m`
- `iconservice/MTIconServiceStoreInvalidator.m`
- `iconservice/MTIconServiceGenerationAdapter.m`
- `iconservice/MTIconServiceABIDiagnostics.h`
- `iconservice/MTIconServiceABIDiagnostics.m`
- `Config.mk`
- `tests/MTIconServiceRuntimeTests.m`
- `tests/iconservice-capability-contract.py` (new)
- `tests/run`
- `tools/iconservice-abi-probe/Makefile`
- `tools/iconservice-abi-probe/control`
- `tools/iconservice-abi-probe/Probe.m`
- `tools/iconservice-abi-probe/README.md`
- `.github/workflows/iconservice-abi-probe.yml`
- `.github/workflows/marktheme-rootless.yml` (new)
- `scripts/ci-remove-obsolete-theos-flag` (new)
- `.gitignore`
