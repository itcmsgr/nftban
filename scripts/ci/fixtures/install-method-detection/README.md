# V108 Item 6 — Install-Method Detection Test Fixtures

Test inputs for `scripts/ci/test-install-method-detection.sh`.

## Per-fixture layout

```
<fixture-name>/
├── fixture.vars                         NFTBAN_TEST_RPM_OWNS=yes|no
│                                        NFTBAN_TEST_DPKG_OWNS=yes|no
│                                        NFTBAN_TEST_GIT_REPO_PRESENT=yes|no
│                                        (.vars extension chosen to dodge
│                                         tools/validate-headers.sh's *.env
│                                         is_conf match — these files are
│                                         test inputs, not real configs)
├── update-history.json                  (optional) mocked history JSON
├── expected.classification              expected `_detect_install_type` output
├── expected.classify-rpm-exit           expected `_classify_for_pkg_mgr_update rpm` exit code
└── expected.classify-deb-exit           expected `_classify_for_pkg_mgr_update deb` exit code
```

## Fixtures

| Fixture | rpm db | dpkg db | history.json first | `.git/` | Class | rpm-exit | deb-exit |
|---|---|---|---|---|---|---|---|
| `pass-rpm-installed` | yes | no | `"rpm"` | no | `rpm` | 0 | 12 |
| `pass-deb-installed` | no | yes | `"deb"` | no | `deb` | 12 | 0 |
| `pass-source-installed` | no | no | `"source"` | no | `source` | 10 | 10 |
| `pass-source-git-clone` | no | no | (no file) | yes | `source` | 10 | 10 |
| `pass-unknown` | no | no | (no file) | no | `unknown` | 11 | 11 |
| `fail-mixed-rpm-history-source` | yes | no | `"source"` | no | `mixed` | 13 | 13 |
| `fail-mixed-deb-history-rpm` | no | yes | `"rpm"` | no | `mixed` | 13 | 13 |
| `fail-cross-family-rpm-on-deb` | no | yes | `"deb"` | no | `deb` | 12 | 0 |
| `pass-history-rpm-confirms-db` | yes | no | `"rpm"` | no | `rpm` | 0 | 12 |

Exit-code legend (per `_classify_for_pkg_mgr_update` in `cli/lib/nftban/cli/cmd_update_detection.sh`):

| Exit | Verdict |
|---|---|
| 0 | PROCEED |
| 10 | NOT_APPLICABLE_SOURCE_INSTALL |
| 11 | NOT_APPLICABLE_UNKNOWN_INSTALL_METHOD |
| 12 | PRECONDITION_MISMATCH_PACKAGER_FAMILY |
| 13 | PRECONDITION_MISMATCH_REQUIRES_OPERATOR |

## Running the suite

```bash
cd "$(git rev-parse --show-toplevel)"
bash scripts/ci/test-install-method-detection.sh suite
```

Or a single fixture:

```bash
bash scripts/ci/test-install-method-detection.sh one pass-source-installed
```

## Notes

- `pass-source-installed` is the dns2 reproduction case (`type:"source"` only entry in history.json).
- `pass-history-rpm-confirms-db` exercises the agreement case — rpm db hit AND history first entry says `rpm`. Verifies the drift check correctly passes through.
- `fail-mixed-*` fixtures exercise the drift detection introduced by V108 Item 6 (package db says one thing, history's first install entry says another).
