package fetcher

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"
)

// FeedResult contains the result of fetching a single feed
type FeedResult struct {
	Name    string
	Content []byte
	Err     error
}

// FetchFeeds downloads multiple feeds concurrently
// urls: map of feed_name -> feed_url
// Returns: slice of FeedResult (one per feed, even if failed)
func FetchFeeds(ctx context.Context, urls map[string]string) []FeedResult {
	results := make(chan FeedResult, len(urls))
	var wg sync.WaitGroup

	// Worker pool: max 8 concurrent downloads
	workers := len(urls)
	if workers > 8 {
		workers = 8
	}
	sem := make(chan struct{}, workers)

	for name, url := range urls {
		wg.Add(1)
		go func(n, u string) {
			defer wg.Done()

			// Acquire semaphore slot
			sem <- struct{}{}
			defer func() { <-sem }() // Release

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

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				results <- FeedResult{Name: n, Err: fmt.Errorf("fetch: %w", err)}
				return
			}
			defer resp.Body.Close()

			if resp.StatusCode != 200 {
				results <- FeedResult{Name: n, Err: fmt.Errorf("HTTP %d", resp.StatusCode)}
				return
			}

			// Read response (limit to 50MB to prevent memory exhaustion)
			body, err := io.ReadAll(io.LimitReader(resp.Body, 50*1024*1024))
			if err != nil {
				results <- FeedResult{Name: n, Err: fmt.Errorf("read body: %w", err)}
				return
			}

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
	return out
}
