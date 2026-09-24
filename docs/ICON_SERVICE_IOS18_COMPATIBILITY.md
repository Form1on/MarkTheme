# MarkTheme Runtime 207: IconFoundation construction compatibility

The implementation adds the iOS 18.1.1 construction sequence observed in the
focused iPhone 11 report (22B91, PID 12328). Device Apply verification and the
macOS package build are separate from the locally completed source changes.

## Root cause and decision

The missing five-argument IFCacheImage initializer blocked generation
validation. In the original runtime, the same failure also blocked store
control through an over-broad validator. Build 206 separated those capabilities;
build 207 preserves that separation and adds the observed image adapter.

The captured hierarchy is IFCacheImage -> IFConcreteImage -> IFImage.
class_getInstanceMethod deliberately accepts inherited methods.

All selected methods must have a non-null IMP, successful dladdr resolution,
the exact expected encoding, and the exact implementation image:
`/System/Library/PrivateFrameworks/IconFoundation.framework/IconFoundation`.
Device code resolves the concrete classes by their existing IFCacheImage and
IFImage names; no class-method substitution is allowed.

| Requirement | Exact encoding |
| --- | --- |
| Legacy initWithCGImage:scale:minimumSize:placeholder:iconSize: | @68@0:8^{CGImage=}16d24{CGSize=dd}32B48{CGSize=dd}52 |
| Split initWithCGImage:scale:minimumSize:placeholder: | @52@0:8^{CGImage=}16d24{CGSize=dd}32B48 |
| setIconSize: | v32@0:8{CGSize=dd}16 |
| bitmapData | @16@0:8 |
| IFImage initWithData:uuid:validationToken: | @40@0:8@16@24@32 |

Selection is capability based, with no OS-version branch:

1. Reject if bitmapData or the final data initializer fails validation.
2. Prefer the validated legacy initializer, independently of split-method availability.
3. Otherwise require both the validated split initializer and setIconSize:.
4. Reject all other combinations.

Diagnostics and production use the same selection function. selectedPath is:
- legacy-cache-image-bitmap-data
- split-cache-image-init-icon-size-bitmap-data
- unavailable

Diagnostics retain individual method checks and report availability for all five
requirements. A successful generation ABI validation also logs its selectedPath.

## Exact execution

The legacy constructor receives the same CGImage, scale, minimumSize,
placeholder and iconSize arguments as before.

The split adapter allocates IFCacheImage, calls the four-argument initializer
with the original geometry, then calls the validated setIconSize: on the
initialized object **before** reading bitmapData. The setter is resolved and
validated on that initialized receiver as an init-family method can substitute
the concrete object.

Both paths use the existing bitmapData getter, original UUID and original
40-byte validation token to initialize the final IFImage. Both restore largest
through the existing validated setter. Typed initializer IMP calls preserve
ARC's consumed receiver and retained result conventions.

No PNG encoding, guessed serialization, KVC or ivar modification is used.
The image composer and all store-control transaction/acknowledgement code are
unchanged from build 206. A matching image ABI is not an acknowledgement:
Apply still requires the existing verified native whole-cache transaction.

## Tests

Passed locally:
- Seven portable tests, including a compiled C executable testing the actual
  production path selector (13 assertions), store independence, construction
  ordering source contracts, native completion/acknowledgement guards and the
  narrowly scoped obsolete-linker-option removal.
- Existing package lifecycle test.
- YAML/plist parsing, shell and workflow script syntax, git diff whitespace checks.
- Byte comparison with build 206 for store invalidator, bootstrap, generation
  adapter, image resolver, runtime invalidation, helper, helper client and Apply
  service: all unchanged.

Added macOS Objective-C fixtures that call the actual production method resolver
and construction function. They cover:
- inherited split methods, legacy preference and legacy-only availability;
- an incompatible legacy method with a valid split fallback;
- each required split method missing, wrong-encoded, class-only, or implemented
  outside the expected image;
- missing/wrong rehydration and serializer rejection on both applicable paths;
- neither path available;
- exact call order and preservation of CGImage, geometry, UUID, token and largest;
- rejection before invoking any candidate method.

Host fixture entry points are guarded by MT_HOST_TESTING and do not exist in
device builds. The CI job also checks the runtime symbols for accidental inclusion.
Only host fixtures use the host test executable as their expected implementation
image; production always supplies the fixed IconFoundation path.

The Objective-C fixtures and full host suite could not run in this Linux workspace:
xcrun is unavailable. The generated-profile check also requires Ruby, unavailable
here. CI runs these checks on macOS before packaging. No successful CI run or
built .deb is claimed by the local checks.

## Full package build

Workflow file: `.github/workflows/marktheme-rootless.yml`
Workflow name: **Build full MarkTheme rootless package**
Artifact name: **MarkTheme-full-rootless-build207**

The workflow uses macOS/Xcode and RootHide Theos pinned to:
`88506b2c22e9e07dd4ed055f23c9e398a117a2c7`, with its pinned submodules.
THEOS uses github.workspace. Only multiply_defined suppress is removed;
-fatal_warnings remains enabled. The four full-package binaries are checked
with the correct `xcrun lipo <binary> -verify_arch arm64 arm64e` syntax.

Expected output after a successful build:

`packages/com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb`

The artifact also includes the toolchain revisions, SHA256SUMS and a compatibility
note. Debian version stays 0.3.1 to preserve the existing release/package audit;
the helper and runtime protocol build is 207. Preserve your original release
package under a different filename before replacing it.

Equivalent commands on a configured macOS/Xcode machine:

```sh
export THEOS=/absolute/path/to/roothide-theos
python3 scripts/ci-remove-obsolete-theos-flag "$THEOS"
MARKTHEME_LOCAL_TEST_ENV_READY=1 ./tests/run
FINALPACKAGE=1 ADDITIONAL_LDFLAGS=-Wl,-fatal_warnings ./scripts/build-packages rootless
```

## Apply the incremental patch and launch CI

This patch is relative to the existing build-206 capability-scoping work.
It preserves prior diagnostics. Do not reapply the earlier patches.

In your WSL checkout, with the downloaded patch in your home directory:

```sh
cd ~/marktheme-src
git switch iconservice-abi-diagnostics
git apply --check ~/marktheme-ios18-build207.patch
git apply ~/marktheme-ios18-build207.patch
git add Config.mk iconservice/MTIconServiceABI.h iconservice/MTIconServiceABI.m \
  iconservice/MTIconServiceImageConstruction.h iconservice/MTIconServiceABIDiagnostics.m \
  tests/MTIconServiceConstructionTests.m tests/MTIconServiceImageConstructionPolicyTests.c \
  tests/MTIconServiceRuntimeTests.m tests/iconservice-capability-contract.py tests/run \
  .github/workflows/marktheme-rootless.yml tools/iconservice-abi-probe/README.md \
  docs/ICON_SERVICE_IOS18_COMPATIBILITY.md
git commit -m "fix(iconservice): support split IconFoundation image construction"
git push origin iconservice-abi-diagnostics
```

If you already have the implementation commit, skip patch application and commit.
Your locally created commit hash will differ from this workspace's commit.

Run **Actions -> Build full MarkTheme rootless package -> Run workflow**, selecting
`iconservice-abi-diagnostics`. Download **MarkTheme-full-rootless-build207** only
after the job succeeds. Extract its .deb.

With GitHub CLI configured on your computer, the equivalent dispatch is:

```sh
gh workflow run marktheme-rootless.yml --ref iconservice-abi-diagnostics
gh run list --workflow marktheme-rootless.yml --branch iconservice-abi-diagnostics --limit 1
```

A workflow must exist on the fork's default branch to be discoverable for manual
dispatch; keep the actual build branch selected when running it.

## Device installation and verification

First retain the original, known-installed rootless 0.3.1 release .deb on the
phone as `/var/mobile/marktheme-rollback-0.3.1.deb`. This must be the original
package, not the new CI package with the same Debian version.

From WSL, in the directory containing the extracted CI artifact:

```sh
scp com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb mobile@172.20.10.2:/var/mobile/
ssh mobile@172.20.10.2
```

On the phone:

```sh
sudo /var/jb/usr/libexec/marktheme-helper status --json
sudo dpkg -i /var/mobile/com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
sudo /var/jb/usr/libexec/marktheme-helper reload-desktop --json
```

Reconnect after the desktop reload if needed, then:

```sh
sudo /var/jb/usr/libexec/marktheme-helper status --json
```

Confirm iconServiceRuntime.runtimeBuild is **207**, available/currentAndLive are
true, and the runtime reaches ready. The selected construction path for the
reported ABI should be split-cache-image-init-icon-size-bitmap-data in the
icon-service-abi log.

Open MarkTheme and **Apply the theme**, then run:

```sh
sudo /var/jb/usr/libexec/marktheme-helper status --json
```

Verify Apply reports success, the runtime remains ready/current/live on build
207, and icons actually change. Status alone is not proof that an Apply transaction
was acknowledged. A failure must remain a failure; keep its status/log outcome.

The old probe is no longer needed. If it is still installed, remove it to avoid
its old diagnostic selection report confusing the runtime-207 log:

```sh
sudo dpkg -r com.hmmzzz.marktheme.abiprobe
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
```

No new probe is included or required.

## Package rollback

Reinstall the saved original package; do not purge MarkTheme's theme data:

```sh
sudo dpkg -i /var/mobile/marktheme-rollback-0.3.1.deb
sudo /var/jb/usr/bin/launchctl kickstart -k user/501/com.apple.iconservices.iconservicesagent
sudo /var/jb/usr/libexec/marktheme-helper reload-desktop --json
```

Reconnect if needed and check:

```sh
sudo /var/jb/usr/libexec/marktheme-helper status --json
```

The build should return to that of the saved package (204 for the original
reported release). Helper theme-generation rollback does not roll back binaries.

## Changed files

- iconservice/MTIconServiceABI.h
- iconservice/MTIconServiceABI.m
- iconservice/MTIconServiceImageConstruction.h (new)
- iconservice/MTIconServiceABIDiagnostics.m
- Config.mk
- tests/MTIconServiceConstructionTests.m (new)
- tests/MTIconServiceImageConstructionPolicyTests.c (new)
- tests/MTIconServiceRuntimeTests.m
- tests/iconservice-capability-contract.py
- tests/run
- .github/workflows/marktheme-rootless.yml
- tools/iconservice-abi-probe/README.md (historical-document pointer only)
- docs/ICON_SERVICE_IOS18_COMPATIBILITY.md (new)
