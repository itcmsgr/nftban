package fetcher

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const CacheDir = "/var/lib/nftban/cache"

// FetchFeedsWithCache downloads feeds and respects ETag/If-Modified-Since
// maxWorkers limits concurrent downloads (pass 0 for default of 8)
// Returns results and a boolean indicating if any feed changed
func FetchFeedsWithCache(ctx context.Context, urls map[string]string, maxWorkers int) ([]FeedResult, bool) {
	results := make(chan FeedResult, len(urls))
	var wg sync.WaitGroup
	var mu sync.Mutex
	anyChanged := false

	// Ensure cache directory exists
	_ = os.MkdirAll(CacheDir, 0755)

	// Worker pool: bounded by maxWorkers (default 8)
	if maxWorkers <= 0 {
		maxWorkers = 8
	}
	workers := len(urls)
	if workers > maxWorkers {
		workers = maxWorkers
	}
	sem := make(chan struct{}, workers)

	for name, url := range urls {
		wg.Add(1)
		go func(n, u string) {
			defer wg.Done()

			// Acquire semaphore slot
			sem <- struct{}{}
			defer func() { <-sem }()

			// Per-request timeout: 10 seconds
			reqCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			defer cancel()

			req, err := http.NewRequestWithContext(reqCtx, "GET", u, nil)
			if err != nil {
				results <- FeedResult{Name: n, Err: fmt.Errorf("create request: %w", err)}
				return
			}

			// User-Agent for politeness
			req.Header.Set("User-Agent", "NFTBan/0.31.0 (+https://nftban.com)")

			// Add ETag from cache if available
			etagFile := filepath.Join(CacheDir, n+".etag")
			if etag, err := os.ReadFile(etagFile); err == nil {
				req.Header.Set("If-None-Match", strings.TrimSpace(string(etag)))
			}

			// Add Last-Modified from cache if available
			modFile := filepath.Join(CacheDir, n+".lastmod")
			if mod, err := os.ReadFile(modFile); err == nil {
				req.Header.Set("If-Modified-Since", strings.TrimSpace(string(mod)))
			}

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				results <- FeedResult{Name: n, Err: fmt.Errorf("fetch: %w", err)}
				return
			}
			defer resp.Body.Close()

			// 304 Not Modified - no changes
			if resp.StatusCode == http.StatusNotModified {
				// Load from cache
				cacheFile := filepath.Join(CacheDir, n+".content")
				content, err := os.ReadFile(cacheFile)
				if err != nil {
					results <- FeedResult{Name: n, Err: fmt.Errorf("cache miss: %w", err)}
					return
				}
				results <- FeedResult{Name: n, Content: content, Err: nil}
				return
			}

			if resp.StatusCode != 200 {
				results <- FeedResult{Name: n, Err: fmt.Errorf("HTTP %d", resp.StatusCode)}
				return
			}

			// Read response (limit to 50MB)
			body, err := io.ReadAll(io.LimitReader(resp.Body, 50*1024*1024))
			if err != nil {
				results <- FeedResult{Name: n, Err: fmt.Errorf("read body: %w", err)}
				return
			}

			// Save to cache
			cacheFile := filepath.Join(CacheDir, n+".content")
			_ = os.WriteFile(cacheFile, body, 0644)

			// Save ETag if present
			if etag := resp.Header.Get("ETag"); etag != "" {
				_ = os.WriteFile(etagFile, []byte(etag), 0644)
			}

			// Save Last-Modified if present
			if mod := resp.Header.Get("Last-Modified"); mod != "" {
				_ = os.WriteFile(modFile, []byte(mod), 0644)
			}

			mu.Lock()
			anyChanged = true
			mu.Unlock()

			results <- FeedResult{Name: n, Content: body}
		}(name, url)
	}

	wg.Wait()
	close(results)

	// Collect all results
	var out []FeedResult
	for r := range results {
		out = append(out, r)
	}
	return out, anyChanged
}
