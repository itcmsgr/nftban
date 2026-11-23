// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 part B2: the credential writer and remover (`nftban feeds abuseipdb key set|remove`).
// The key arrives on stdin, never argv. It is written root:root 0600 AT CREATION inside its own
// directory (os.Root: no escape, no link followed): exclusive temp file, owned through its
// descriptor, synced, renamed over the target (a link at the target is replaced, never followed).
// fhs-spec: /etc/nftban/abuseipdb.key root:root 0600 (exact entry).

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// credentialOwnerGID is the group of a written credential file (root). A variable so tests can run
// unprivileged (with credentialOwnerUID).
var credentialOwnerGID = 0

// WriteCredentialFile stores key at path (first entry and rotation). Errors never contain the key.
func WriteCredentialFile(path, key string) error {
	key = strings.TrimSpace(key)
	if err := validateKeyToken(key); err != nil {
		return fmt.Errorf("%w: %s", ErrCredentialInvalid, err.Error())
	}
	dir, name := filepath.Split(path)
	if name == "" {
		return fmt.Errorf("invalid credential path %q", path)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return fmt.Errorf("credential directory %s: %w", dir, err)
	}
	defer func() { _ = root.Close() }()
	tmp := name + ".tmp"
	if err := root.Remove(tmp); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("clearing a stale temp file: %w", err)
	}
	f, err := root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("creating the credential file: %w", err)
	}
	fail := func(e error) error {
		_ = f.Close()
		_ = root.Remove(tmp)
		return e
	}
	if err := f.Chown(credentialOwnerUID, credentialOwnerGID); err != nil {
		return fail(fmt.Errorf("owning the credential file: %w", err))
	}
	if err := f.Chmod(0o600); err != nil {
		return fail(fmt.Errorf("mode of the credential file: %w", err))
	}
	if _, err := f.WriteString(key + "\n"); err != nil {
		return fail(fmt.Errorf("writing the credential file failed"))
	}
	if err := f.Sync(); err != nil {
		return fail(fmt.Errorf("syncing the credential file: %w", err))
	}
	if err := f.Close(); err != nil {
		_ = root.Remove(tmp)
		return fmt.Errorf("closing the credential file: %w", err)
	}
	if err := root.Rename(tmp, name); err != nil {
		_ = root.Remove(tmp)
		return fmt.Errorf("saving the credential file: %w", err)
	}
	return nil
}

// RemoveCredentialFile deletes the credential file (a link there is removed itself, never its
// target). A missing file is ErrCredentialMissing.
func RemoveCredentialFile(path string) error {
	dir, name := filepath.Split(path)
	root, err := os.OpenRoot(dir)
	if err != nil {
		return fmt.Errorf("credential directory %s: %w", dir, err)
	}
	defer func() { _ = root.Close() }()
	if err := root.Remove(name); err != nil {
		if os.IsNotExist(err) {
			return fmt.Errorf("%w: %s", ErrCredentialMissing, path)
		}
		return fmt.Errorf("removing %s: %w", path, err)
	}
	return nil
}
