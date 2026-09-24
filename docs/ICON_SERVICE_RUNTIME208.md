# Runtime 208: application-icon execution evidence

Runtime 207 validates both observed IconFoundation construction paths and
verifies the native type-2 cache transaction, but neither event proves that
`ISGenerationRequest -generateImageReturningRecordIdentifiers:` generated a
themed application icon. On the reported iOS 18.1.1 phone, the stock icons
after a successful Apply demonstrate that this distinction matters. The
available device ABI captures show that the hook exists with the expected
encoding; they do not show that it is invoked during the cache transaction,
nor identify another generation entry point. Runtime 208 makes no claim to
know an unobserved selector or private return contract.

The existing helper `status --json` now includes an atomic, process-local,
bounded execution snapshot from the live iconservicesagent. The counts are
cumulative in that daemon process: `generationHookCallCount`,
`resolverCallCount`, `themedResolverMatchCount`, `replacementCGImageCount`,
`replacementIFImageCount`, `replacementReturnedCount`, `passthroughCount`, and
`constructionFailureCount`. `generationAdapterInstalled` and
`selectedImageConstructionPath` show installation and the validated image ABI.
`lastBundleIdentifier` reports up to 47 ASCII bytes of the last validated
request (with `lastBundleIdentifierTruncated` when applicable). The three
`generationCycle*` values scope the decision to the Apply sequence. These
fields appear only when `telemetryAvailable` is true and the PID/build matches
the live daemon. The counters do not invoke additional private methods or
change image rendering.

For a Generation with `icons.static`, `icons.mask`, or `icons.overlay`, Apply
now acknowledges only after both the existing verified whole-cache operation
and at least one returned native `IFImage` replacement produced by the current
Generation during that cycle. A 350 ms observation window follows the native
operation; it fits inside the helper's existing 5 s acknowledgement deadline
after the cache operation's 4 s timeout. `generation-not-observed` means zero
hook calls; `replacement-not-produced` means calls occurred but no replacement
for this Generation was returned. Both stages can accept a later retry. A
theme without application-icon modules retains its previous verified-cache
contract. An unchanged Generation can reuse a previous verified transaction
only when that prior cycle already satisfied this stronger contract.

No iOS 18.1.1 replacement generation hook or alternative image pipeline can
be safely chosen from the current metadata alone. If Runtime 208 reports zero
hook calls, that is specific evidence the installed hook is not reached during
the observed cycle, and more runtime identity/entry-point evidence is needed
before writing another adapter. If calls occur without a match, inspect the
last identifier and count progression. Even a returned replacement does not,
by itself, prove that SpringBoard accepted or displayed its pixels; the
device's visible icons remain the final check.

Build the complete package on macOS through **Build full MarkTheme rootless
package** (`.github/workflows/marktheme-rootless.yml`). Download the artifact
**MarkTheme-full-rootless-build208**. It contains
`com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb` with arm64 and arm64e slices.
The job runs host tests and audits all four package binaries before uploading.
From a Mac with the supported RootHide Theos checkout, the equivalent build
is `THEOS=/path/to/roothide-theos ./scripts/build-packages rootless`.

Keep a copy of the existing Runtime 207 `.deb` on the phone at
`/var/mobile/marktheme-runtime207.deb`. Place the new `.deb` at
`/var/mobile/com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb`, then run:

```sh
sudo dpkg -i /var/mobile/com.hmmzzz.marktheme_0.3.1_iphoneos-arm64.deb
sudo /var/jb/usr/libexec/marktheme-helper status --json
# Apply the selected theme in MarkTheme, then inspect the same process/cycle:
sudo /var/jb/usr/libexec/marktheme-helper status --json
```

Rollback to the saved Runtime 207 package with:

```sh
sudo dpkg -i /var/mobile/marktheme-runtime207.deb
```

This is an incremental change from `e973882` (Runtime 207). Locally, the
portable capability/execution contracts and the package lifecycle contract
pass; the Objective-C host suite and the actual `.deb` build require macOS
Xcode/Theos and are run by the workflow. No device execution or visual result
for Runtime 208 has been claimed.
