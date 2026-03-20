// =============================================================================
// NFTBan - Tests for feed loading and syncing
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="feeds_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for feed loading and syncing"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package feeds

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/pkg/model"
)

// =============================================================================
// Merge tests (pure logic, no filesystem)
// =============================================================================

func TestMerge_EmptyFeeds(t *testing.T) {
	feeds := make(map[string]*model.SetData)
	merged := Merge(feeds)
	if merged == nil {
		t.Fatal("expected non-nil merged SetData")
	}
	if !merged.IsEmpty() {
		t.Errorf("expected empty merged set, got count=%d", merged.Count)
	}
}

func TestMerge_SingleFeed(t *testing.T) {
	feeds := make(map[string]*model.SetData)
	sd := model.NewSetData("test")
	sd.AddIPv4("1.2.3.4")
	sd.AddIPv4("5.6.7.8")
	sd.AddIPv6("2001:db8::1")
	feeds["test"] = sd

	merged := Merge(feeds)
	if merged.Count != 3 {
		t.Errorf("merged.Count = %d, want 3", merged.Count)
	}
	if len(merged.IPv4) != 2 {
		t.Errorf("len(merged.IPv4) = %d, want 2", len(merged.IPv4))
	}
	if len(merged.IPv6) != 1 {
		t.Errorf("len(merged.IPv6) = %d, want 1", len(merged.IPv6))
	}
}

func TestMerge_MultipleFeeds(t *testing.T) {
	feeds := make(map[string]*model.SetData)

	sd1 := model.NewSetData("feed1")
	sd1.AddIPv4("1.2.3.4")
	sd1.AddIPv4("5.6.7.8")
	feeds["feed1"] = sd1

	sd2 := model.NewSetData("feed2")
	sd2.AddIPv4("10.0.0.1")
	sd2.AddIPv6("::1")
	feeds["feed2"] = sd2

	merged := Merge(feeds)
	if merged.Count != 4 {
		t.Errorf("merged.Count = %d, want 4", merged.Count)
	}
	if len(merged.IPv4) != 3 {
		t.Errorf("len(merged.IPv4) = %d, want 3", len(merged.IPv4))
	}
	if len(merged.IPv6) != 1 {
		t.Errorf("len(merged.IPv6) = %d, want 1", len(merged.IPv6))
	}
	if merged.Source != "merged_feeds" {
		t.Errorf("merged.Source = %q, want %q", merged.Source, "merged_feeds")
	}
}

// =============================================================================
// LoadFeed tests (uses temp files)
// =============================================================================

func createTempFeedFile(t *testing.T, dir, name, content string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0644); err != nil {
		t.Fatalf("failed to create temp feed file: %v", err)
	}
}

func TestLoadFeed_BasicIPv4(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "TEST_FEED.txt", `# Test feed
1.2.3.4
5.6.7.8
10.0.0.1
`)

	data, err := LoadFeed(dir, "test-feed")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if data == nil {
		t.Fatal("expected non-nil SetData")
	}
	if len(data.IPv4) != 3 {
		t.Errorf("len(IPv4) = %d, want 3", len(data.IPv4))
	}
	if len(data.IPv6) != 0 {
		t.Errorf("len(IPv6) = %d, want 0", len(data.IPv6))
	}
	if data.Count != 3 {
		t.Errorf("Count = %d, want 3", data.Count)
	}
}

func TestLoadFeed_MixedIPv4IPv6(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "MIXED.txt", `# Mixed feed
1.2.3.4
2001:db8::1
10.0.0.0/8
::1
`)

	data, err := LoadFeed(dir, "mixed")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// 1.2.3.4 (IPv4), 10.0.0.0/8 (IPv4 CIDR) => 2 IPv4
	// 2001:db8::1 (IPv6), ::1 (IPv6) => 2 IPv6
	if len(data.IPv4) != 2 {
		t.Errorf("len(IPv4) = %d, want 2", len(data.IPv4))
	}
	if len(data.IPv6) != 2 {
		t.Errorf("len(IPv6) = %d, want 2", len(data.IPv6))
	}
}

func TestLoadFeed_CommentsAndBlanks(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "COMMENTS.txt", `# Header comment
; Another comment

1.2.3.4

# Middle comment
5.6.7.8

`)

	data, err := LoadFeed(dir, "comments")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if data.Count != 2 {
		t.Errorf("Count = %d, want 2 (should skip comments/blanks)", data.Count)
	}
}

func TestLoadFeed_FileNotFound(t *testing.T) {
	dir := t.TempDir()
	_, err := LoadFeed(dir, "nonexistent")
	if err == nil {
		t.Error("expected error for missing feed file")
	}
}

func TestLoadFeed_EmptyFile(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "EMPTY.txt", "")

	data, err := LoadFeed(dir, "empty")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if data.Count != 0 {
		t.Errorf("Count = %d, want 0", data.Count)
	}
}

func TestLoadFeed_NormalizedName(t *testing.T) {
	dir := t.TempDir()
	// Filename uses uppercase + underscores, lookup uses lowercase + hyphens
	createTempFeedFile(t, dir, "MY_FEED.txt", "1.2.3.4\n")

	data, err := LoadFeed(dir, "my-feed")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if data.Source != "MY_FEED" {
		t.Errorf("Source = %q, want %q", data.Source, "MY_FEED")
	}
}

func TestLoadFeed_InvalidLinesSkipped(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "BADLINES.txt", `1.2.3.4
not-an-ip
5.6.7.8
256.1.1.1
10.0.0.1
`)

	data, err := LoadFeed(dir, "badlines")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Only 3 valid IPs (invalid ones are warned but skipped)
	if data.Count != 3 {
		t.Errorf("Count = %d, want 3", data.Count)
	}
}

// =============================================================================
// Build tests
// =============================================================================

func TestBuild_WithSpecificFeeds(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "FEED_A.txt", "1.2.3.4\n5.6.7.8\n")
	createTempFeedFile(t, dir, "FEED_B.txt", "10.0.0.1\n")

	result, err := Build(dir, []string{"feed-a", "feed-b"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 2 {
		t.Errorf("len(result) = %d, want 2", len(result))
	}
}

func TestBuild_AutoDiscover(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "AUTO1.txt", "1.2.3.4\n")
	createTempFeedFile(t, dir, "AUTO2.txt", "5.6.7.8\n")
	// Non-.txt files should be ignored
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("ignore"), 0644); err != nil {
		t.Fatal(err)
	}

	result, err := Build(dir, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 2 {
		t.Errorf("len(result) = %d, want 2", len(result))
	}
}

func TestBuild_EmptyDirectory(t *testing.T) {
	dir := t.TempDir()
	result, err := Build(dir, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("len(result) = %d, want 0", len(result))
	}
}

func TestBuild_NonexistentDir(t *testing.T) {
	_, err := Build("/tmp/nonexistent-feeds-dir-12345", nil)
	if err == nil {
		t.Error("expected error for nonexistent directory")
	}
}

// =============================================================================
// LoadAllFeeds tests
// =============================================================================

func TestLoadAllFeeds_BasicOperation(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "test1.txt", "1.2.3.4\n5.6.7.8\n10.0.0.0/24\n")
	createTempFeedFile(t, dir, "test2.txt", "192.168.1.1\n2001:db8::1\n")

	ipv4, ipv6, ipv4CIDR, ipv6CIDR, feedsInfo, err := LoadAllFeeds(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// test1.txt has 2 single IPs + 1 CIDR, test2.txt has 1 single IP + 1 IPv6
	if len(ipv4) != 3 { // 1.2.3.4, 5.6.7.8, 192.168.1.1
		t.Errorf("len(ipv4) = %d, want 3", len(ipv4))
	}
	if len(ipv6) != 1 { // 2001:db8::1
		t.Errorf("len(ipv6) = %d, want 1", len(ipv6))
	}
	if len(ipv4CIDR) != 1 { // 10.0.0.0/24
		t.Errorf("len(ipv4CIDR) = %d, want 1", len(ipv4CIDR))
	}
	if len(ipv6CIDR) != 0 {
		t.Errorf("len(ipv6CIDR) = %d, want 0", len(ipv6CIDR))
	}
	if len(feedsInfo) != 2 {
		t.Errorf("len(feedsInfo) = %d, want 2", len(feedsInfo))
	}
}

func TestLoadAllFeeds_NonexistentDir(t *testing.T) {
	ipv4, ipv6, ipv4CIDR, ipv6CIDR, feedsInfo, err := LoadAllFeeds("/tmp/nonexistent-feeds-12345")
	if err != nil {
		t.Fatalf("unexpected error (should be empty, not error): %v", err)
	}
	// Should return empty sets, no error
	if len(ipv4)+len(ipv6)+len(ipv4CIDR)+len(ipv6CIDR) != 0 {
		t.Error("expected all empty sets for nonexistent dir")
	}
	if len(feedsInfo) != 0 {
		t.Errorf("len(feedsInfo) = %d, want 0", len(feedsInfo))
	}
}

func TestLoadAllFeeds_SkipsDirectories(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "feed1.txt", "1.2.3.4\n")
	// Create a subdirectory that should be skipped
	if err := os.Mkdir(filepath.Join(dir, "subdir"), 0755); err != nil {
		t.Fatal(err)
	}

	_, _, _, _, feedsInfo, err := LoadAllFeeds(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(feedsInfo) != 1 {
		t.Errorf("len(feedsInfo) = %d, want 1 (should skip subdirectories)", len(feedsInfo))
	}
}

func TestLoadAllFeeds_SkipsNonTxtFiles(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "feed1.txt", "1.2.3.4\n")
	createTempFeedFile(t, dir, "notes.md", "this is not a feed\n")
	createTempFeedFile(t, dir, "data.json", "{}\n")

	_, _, _, _, feedsInfo, err := LoadAllFeeds(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(feedsInfo) != 1 {
		t.Errorf("len(feedsInfo) = %d, want 1 (should skip non-.txt files)", len(feedsInfo))
	}
}

func TestLoadAllFeeds_Deduplication(t *testing.T) {
	dir := t.TempDir()
	// Same IP in two feeds
	createTempFeedFile(t, dir, "feed1.txt", "1.2.3.4\n5.6.7.8\n")
	createTempFeedFile(t, dir, "feed2.txt", "1.2.3.4\n10.0.0.1\n")

	ipv4, _, _, _, _, err := LoadAllFeeds(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// 1.2.3.4 appears in both feeds but should only be in the set once
	if len(ipv4) != 3 {
		t.Errorf("len(ipv4) = %d, want 3 (dedup across feeds)", len(ipv4))
	}
}

// =============================================================================
// LoadSpecificFeed tests
// =============================================================================

func TestLoadSpecificFeed_Found(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "spamhaus.txt", "1.2.3.4\n2001:db8::1\n10.0.0.0/8\n")

	ipv4, ipv6, ipv4CIDR, ipv6CIDR, err := LoadSpecificFeed(dir, "spamhaus")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 1 {
		t.Errorf("len(ipv4) = %d, want 1", len(ipv4))
	}
	if len(ipv6) != 1 {
		t.Errorf("len(ipv6) = %d, want 1", len(ipv6))
	}
	if len(ipv4CIDR) != 1 {
		t.Errorf("len(ipv4CIDR) = %d, want 1", len(ipv4CIDR))
	}
	if len(ipv6CIDR) != 0 {
		t.Errorf("len(ipv6CIDR) = %d, want 0", len(ipv6CIDR))
	}
}

func TestLoadSpecificFeed_NotFound(t *testing.T) {
	dir := t.TempDir()
	_, _, _, _, err := LoadSpecificFeed(dir, "nonexistent")
	if err == nil {
		t.Error("expected error for missing feed")
	}
}

// =============================================================================
// ListAvailableFeeds tests
// =============================================================================

func TestListAvailableFeeds(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "spamhaus.txt", "1.2.3.4\n")
	createTempFeedFile(t, dir, "firehol.txt", "5.6.7.8\n")
	createTempFeedFile(t, dir, "library.txt", "internal\n") // Should be excluded
	createTempFeedFile(t, dir, "notes.md", "not a feed\n")  // Not .txt

	feeds, err := ListAvailableFeeds(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// "library" is excluded, "notes.md" is not .txt
	if len(feeds) != 2 {
		t.Errorf("len(feeds) = %d, want 2", len(feeds))
	}

	// Check that "library" is not in the list
	for _, f := range feeds {
		if f == "library" {
			t.Error("'library' should be excluded from feed list")
		}
	}
}

func TestListAvailableFeeds_NonexistentDir(t *testing.T) {
	feeds, err := ListAvailableFeeds("/tmp/nonexistent-feeds-dir-67890")
	if err != nil {
		t.Fatalf("unexpected error (should return nil, nil): %v", err)
	}
	if feeds != nil {
		t.Errorf("expected nil for nonexistent dir, got %v", feeds)
	}
}

// =============================================================================
// FeedInfo tests
// =============================================================================

func TestFeedInfo_Counts(t *testing.T) {
	dir := t.TempDir()
	createTempFeedFile(t, dir, "counted.txt", "1.2.3.4\n5.6.7.8\n10.0.0.0/24\n2001:db8::1\n")

	_, _, _, _, feedsInfo, err := LoadAllFeeds(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(feedsInfo) != 1 {
		t.Fatalf("expected 1 feed info, got %d", len(feedsInfo))
	}

	fi := feedsInfo[0]
	if fi.Name != "counted" {
		t.Errorf("Name = %q, want %q", fi.Name, "counted")
	}
	// IPv4Count = single IPs (2) + CIDRs (1) = 3
	if fi.IPv4Count != 3 {
		t.Errorf("IPv4Count = %d, want 3", fi.IPv4Count)
	}
	// IPv6Count = single IPs (1) + CIDRs (0) = 1
	if fi.IPv6Count != 1 {
		t.Errorf("IPv6Count = %d, want 1", fi.IPv6Count)
	}
}
