# V108 Item 2 — +i Lifecycle Matrix Test Fixtures

Test inputs for `scripts/ci/test-immutable-lifecycle-matrix.sh`.

## Layout

Each fixture directory contains a complete minimal set of files that mock
the 4 source surfaces:

```
<fixture-name>/
├── matrix.yaml                      mocked build/+i-lifecycle-matrix.yaml
├── authority.go                     mocked internal/installer/validate/authority.go fragment
├── build_nftban.sh                  mocked packaging/build_nftban.sh fragment (RPM scriptlets only)
├── deb-preinst                      mocked packaging/deb/preinst
├── deb-postinst                     mocked packaging/deb/postinst
├── deb-prerm                        mocked packaging/deb/prerm
├── expected.exit                    expected gate exit code
└── expected.report                  expected report substring
```

The gate is invoked as:

```bash
bash scripts/ci/test-immutable-lifecycle-matrix.sh scan \
    --matrix-yaml=<fixture>/matrix.yaml \
    --authority-go=<fixture>/authority.go.fixture \
    --build-sh=<fixture>/build_nftban.sh.fixture \
    --deb-preinst=<fixture>/deb-preinst.fixture \
    --deb-postinst=<fixture>/deb-postinst.fixture \
    --deb-prerm=<fixture>/deb-prerm.fixture
```

## Fixtures

| Fixture | Probes | Expected |
|---|---|---|
| `pass-baseline-complete` | All 5 hooks cover the 2 canonical files | exit 0 |
| `fail-yaml-file-not-in-go` | Matrix yaml declares an extra file not in Go SetImmutableFlags | exit 1, `YAML_FILE_NOT_IN_GO` |
| `fail-go-file-not-in-yaml` | Go SetImmutableFlags has an extra file not in matrix yaml | exit 1, `GO_FILE_NOT_IN_YAML` |
| `fail-missing-rpm-pretrans` | Matrix requires; RPM `%pretrans` doesn't strip | exit 1, `MISSING_RPM_PRETRANS_STRIP` |
| `fail-missing-rpm-preun` | Matrix requires; RPM `%preun` doesn't strip | exit 1, `MISSING_RPM_PREUN_STRIP` |
| `fail-missing-deb-preinst` | Matrix requires; DEB preinst doesn't strip | exit 1, `MISSING_DEB_PREINST_STRIP` |
| `fail-missing-deb-postinst` | Matrix requires; DEB postinst doesn't strip | exit 1, `MISSING_DEB_POSTINST_STRIP` |
| `fail-missing-deb-prerm` | Matrix requires; DEB prerm doesn't strip | exit 1, `MISSING_DEB_PRERM_STRIP` |

## Running the suite

A simple runner iterates the fixtures and compares actual vs expected:

```bash
cd /home/gituser/github/nftban
FIX=scripts/ci/fixtures/immutable-lifecycle-matrix
for d in "$FIX"/*/; do
    name=$(basename "$d")
    expected_exit=$(cat "$d/expected.exit" 2>/dev/null | tr -d '[:space:]')
    set +e
    bash scripts/ci/test-immutable-lifecycle-matrix.sh scan \
        --matrix-yaml="$d/matrix.yaml" \
        --authority-go="$d/authority.go" \
        --build-sh="$d/build_nftban.sh" \
        --deb-preinst="$d/deb-preinst" \
        --deb-postinst="$d/deb-postinst" \
        --deb-prerm="$d/deb-prerm" >/dev/null 2>&1
    actual=$?
    set -e
    [[ "$actual" == "$expected_exit" ]] && echo "✅ $name" || echo "❌ $name (got=$actual want=$expected_exit)"
done
```
