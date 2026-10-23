// =============================================================================
// NFTBan - Ruleset content: kernel set reader (nft -j list set)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ruleset-kernel"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-22"
// meta:description="Reads one NFTBan set from the kernel as JSON and returns its elements with remaining lifetime (shapes verified on nft 1.0.9: string, prefix, range, concat, elem{val,timeout,expires} in seconds)"
// meta:inventory.binaries="nft"
// meta:inventory.privileges="root"
// =============================================================================

package ruleset

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// NftSetReader reads sets with `nft -j list set <family> nftban <set>`. A set or table
// that does not exist is an empty result, not an error.
func NftSetReader(family, set string) ([]Element, error) {
	cmd := exec.Command("nft", "-j", "list", "set", family, "nftban", set) // #nosec G204 -- fixed table, constant set names
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		if strings.Contains(stderr.String(), "No such file or directory") {
			return nil, nil
		}
		return nil, fmt.Errorf("nft list set %s nftban %s: %v: %s", family, set, err, strings.TrimSpace(stderr.String()))
	}
	return ParseSetJSON(out)
}

// ParseSetJSON parses `nft -j list set` output.
func ParseSetJSON(data []byte) ([]Element, error) {
	var doc struct {
		Nftables []map[string]json.RawMessage `json:"nftables"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("decode nft json: %w", err)
	}
	var out []Element
	for _, obj := range doc.Nftables {
		raw, ok := obj["set"]
		if !ok {
			continue
		}
		var set struct {
			Elem []json.RawMessage `json:"elem"`
		}
		if err := json.Unmarshal(raw, &set); err != nil {
			return nil, fmt.Errorf("decode set: %w", err)
		}
		for _, e := range set.Elem {
			el, err := parseElement(e)
			if err != nil {
				return nil, err
			}
			out = append(out, el)
		}
	}
	return out, nil
}

func parseElement(raw json.RawMessage) (Element, error) {
	var wrapped struct {
		Elem *struct {
			Val     json.RawMessage `json:"val"`
			Timeout *int64          `json:"timeout"`
			Expires *int64          `json:"expires"`
		} `json:"elem"`
	}
	if err := json.Unmarshal(raw, &wrapped); err == nil && wrapped.Elem != nil {
		key, err := parseValue(wrapped.Elem.Val)
		if err != nil {
			return Element{}, err
		}
		el := Element{Key: key}
		switch {
		case wrapped.Elem.Expires != nil:
			el.HasTimeout, el.Remaining = true, time.Duration(*wrapped.Elem.Expires)*time.Second
		case wrapped.Elem.Timeout != nil:
			// No expiry reported: the full timeout is the only bound known.
			el.HasTimeout, el.Remaining = true, time.Duration(*wrapped.Elem.Timeout)*time.Second
		}
		return el, nil
	}
	key, err := parseValue(raw)
	return Element{Key: key}, err
}

func parseValue(raw json.RawMessage) (string, error) {
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s, nil
	}
	var n json.Number
	if err := json.Unmarshal(raw, &n); err == nil {
		return n.String(), nil
	}
	var obj struct {
		Prefix *struct {
			Addr string `json:"addr"`
			Len  int    `json:"len"`
		} `json:"prefix"`
		Range  []json.RawMessage `json:"range"`
		Concat []json.RawMessage `json:"concat"`
	}
	if err := json.Unmarshal(raw, &obj); err != nil {
		return "", fmt.Errorf("unsupported nft element %s", string(raw))
	}
	switch {
	case obj.Prefix != nil:
		return fmt.Sprintf("%s/%d", obj.Prefix.Addr, obj.Prefix.Len), nil
	case len(obj.Range) == 2:
		a, err := parseValue(obj.Range[0])
		if err != nil {
			return "", err
		}
		b, err := parseValue(obj.Range[1])
		if err != nil {
			return "", err
		}
		return a + "-" + b, nil
	case len(obj.Concat) > 0:
		parts := make([]string, 0, len(obj.Concat))
		for _, c := range obj.Concat {
			p, err := parseValue(c)
			if err != nil {
				return "", err
			}
			parts = append(parts, p)
		}
		return strings.Join(parts, " . "), nil
	}
	return "", fmt.Errorf("unsupported nft element %s", string(raw))
}
