# B2 driver inventory

The collector records installation-stage observations inside the isolated Windows Guest. It exports neutral driver, catalog and service aliases. Paths, service names, accounts, kernel addresses and certificate serials or thumbprints are never exported.

Run a syntax check with the Guest PowerShell parser before execution. Use an elevated session; Windows 11 24H2 can return null image bases unless the calling process has enabled SeDebugPrivilege. The collector requests that privilege only for its own process and records failure as unknown or partial enumeration.

1. Run `b2-driver-inventory.ps1` with `-Stage before`, a fresh Guest-local `-StateFile`, and a neutral `-OutputFile`.
2. Follow the official installer flow and preserve separately reviewed, redacted dialog captures.
3. Run the same collector with `-Stage after`, the same `-StateFile`, the actual installation roots passed through `-InstallRoot`, and another neutral `-OutputFile`.
4. Use `-Stage diagnostic` with the same state for additional snapshots. Remove the Guest-local state after sampling and report verification.

The state file contains DPAPI-protected random correlation material and HMAC identity keys. It contains no raw service names or paths and is not an exported evidence attachment. It lets before/after snapshots reuse aliases and detect newly registered services, new candidate paths and changed file hashes.

The state file uses an explicit ACL limited to the collecting identity, SYSTEM and local Administrators. Caught errors export only a standard exception type and script line. Full exception records are written beside the state file with the suffix `.private-errors.jsonl` under the same private ACL, and must be read only through the existing redactor. Neither private file is an evidence attachment. Remove both after diagnosis and report verification.

By default, signatures are sampled for new, changed or installation-root candidates. `-FullSignatureInventory` additionally samples all system candidates. Installation scans skip reparse points and stop at `-MaxRootDriverFiles` or `-MaxRootDirectories`; the report records limits and truncation. An empty root scan or lack of emitted drivers at one stage cannot establish that the publisher distributes no ARM64 driver.

Each candidate separates these observations:

- PE Machine, size, SHA-256 and a numeric file-version resource identify the on-disk binary at the sampled time. Machine classification requires valid DOS/PE signatures, a supported Optional Header magic and complete bounded Optional Header/data-directory storage.
- Embedded trust uses explicit WinVerifyTrust file verification and separately records whether the PE certificate table is present.
- Catalog trust hashes the member with SHA256 and SHA1, looks up registered local catalog memberships, and verifies each candidate using explicit WinVerifyTrust catalog-member data. Catalog paths become aliases; hashes remain public binary fingerprints.
- PowerShell Authenticode results also record `SignatureType`. A catalog result from this cmdlet must not be mislabeled as an embedded signature.
- Actual load observations require documented PSAPI loaded-image path correlation. A service being registered or running alone does not establish a loaded image. Missing privilege, null bases, truncation or unresolved paths leave unmatched images unknown.

Default trust checks use cached trust data and do not perform online revocation checks. `-AllowOnlineSignatureChecks` requests chain revocation checks; the report records that request. Generic file or catalog trust does not prove Windows kernel-signing policy acceptance. Loaded image bytes are not read or dumped, so identity confirmation is limited to documented path correlation with the on-disk candidate.

Catalog absence is reported only after both hash algorithms and catalog enumeration complete without error. Failed hashing, catalog information queries, native enumeration errors or truncation leave zero-match results unknown and matched results partial.

SCM and Code Integrity events are attached to the sampling stage with neutral related aliases, event IDs and structured native/status codes. Raw event messages are omitted because they can contain personal paths or identifiers. Visible official conflicts or refusals require separate redacted captures.

Event data is read with namespace-independent XML nodes. Missing EventData produces no values, and one malformed event cannot stop the remaining events in that log. Error counts and safe diagnostic locations remain in the exported report.

The output is an inventory attachment, not a complete local-observations report. Transform only relevant vendor candidates into the report and cite the attachment hash. Preserve scan and verification limits. A native ARM64 binary alone proves neither publisher support nor acceptance of the virtualized Guest.
