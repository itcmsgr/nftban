// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// Provider credential file (v1.238, owner decision D3): a root-only key file read by the Go HTTP
// client, e.g. /etc/nftban/abuseipdb.key root:root 0600, declared in the canonical FHS spec and
// restored in place by the generated policy. The key never appears in logs, diagnostics, argv or
// output: errors from this file name the problem, never the content.

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// credentialOwnerUID is the required owner of a key file (root). A variable so tests can run
// unprivileged.
var credentialOwnerUID = 0

// Credential errors (stable, content-free).
var (
	ErrCredentialMissing = errors.New("credential file not found")
	ErrCredentialUnsafe  = errors.New("credential file unsafe")
	ErrCredentialInvalid = errors.New("credential file content invalid")
)

const credentialMaxBytes = 1024

// ReadCredentialFile returns the key from path, or an error that never contains the key. The file
// must be a regular file (not a symlink), owned by root, with no group/other access, and contain
// one token of 16-256 characters from [A-Za-z0-9._-] (surrounding whitespace ignored).
func ReadCredentialFile(path string) (string, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("%w: %s", ErrCredentialMissing, path)
		}
		return "", fmt.Errorf("%w: %s: cannot stat", ErrCredentialUnsafe, path)
	}
	if err := credentialFileSafe(path, fi); err != nil {
		return "", err
	}
	// opened inside its own directory (os.Root: no escape) and never through a final symlink
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return "", fmt.Errorf("%w: %s: cannot open directory", ErrCredentialUnsafe, path)
	}
	defer func() { _ = root.Close() }()
	f, err := root.OpenFile(filepath.Base(path), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return "", fmt.Errorf("%w: %s: cannot open", ErrCredentialUnsafe, path)
	}
	defer func() { _ = f.Close() }()
	// re-check the opened inode: the path may not have been swapped between Lstat and open
	ofi, err := f.Stat()
	if err != nil || !os.SameFile(fi, ofi) {
		return "", fmt.Errorf("%w: %s: changed while opening", ErrCredentialUnsafe, path)
	}
	if err := credentialFileSafe(path, ofi); err != nil {
		return "", err
	}
	b, err := io.ReadAll(io.LimitReader(f, credentialMaxBytes+1))
	if err != nil {
		return "", fmt.Errorf("%w: %s: cannot read", ErrCredentialUnsafe, path)
	}
	if len(b) > credentialMaxBytes {
		return "", fmt.Errorf("%w: %s: larger than %d bytes", ErrCredentialInvalid, path, credentialMaxBytes)
	}
	key := strings.TrimSpace(string(b))
	if err := validateKeyToken(key); err != nil {
		return "", fmt.Errorf("%w: %s: %s", ErrCredentialInvalid, path, err.Error())
	}
	return key, nil
}

// validateKeyToken: one token of 16-256 characters from [A-Za-z0-9._-]. The message never
// contains the key.
func validateKeyToken(key string) error {
	if len(key) < 16 || len(key) > 256 {
		return errors.New("expected one token of 16-256 characters")
	}
	for _, r := range key {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '_' || r == '-') {
			return errors.New("unexpected character (one token, letters/digits/._- only)")
		}
	}
	return nil
}

// CredentialStatus reports presence and safety without reading the content: "absent", "ok", or
// the reason it is unsafe. For `status` / `key status` output.
func CredentialStatus(path string) string {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "absent"
		}
		if os.IsPermission(err) {
			return "unknown (checking it needs root)"
		}
		return "unsafe: cannot stat"
	}
	if err := credentialFileSafe(path, fi); err != nil {
		return "unsafe: " + strings.TrimPrefix(err.Error(), ErrCredentialUnsafe.Error()+": "+path+": ")
	}
	return "ok"
}

func credentialFileSafe(path string, fi os.FileInfo) error {
	if fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%w: %s: is a symbolic link", ErrCredentialUnsafe, path)
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("%w: %s: not a regular file", ErrCredentialUnsafe, path)
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("%w: %s: cannot read owner", ErrCredentialUnsafe, path)
	}
	if int(st.Uid) != credentialOwnerUID {
		return fmt.Errorf("%w: %s: owned by uid %d, must be root", ErrCredentialUnsafe, path, st.Uid)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("%w: %s: mode %04o, must be 0600 (no group/other access)", ErrCredentialUnsafe, path, fi.Mode().Perm())
	}
	return nil
}
