package safety

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// Snapshot tracks previous run's state for delta comparison
type Snapshot struct {
	TotalV4 int    `json:"total_v4"`
	TotalV6 int    `json:"total_v6"`
	Hash    string `json:"hash"`
}

// LoadSnapshot loads the previous run snapshot
func LoadSnapshot(cacheDir string) (Snapshot, error) {
	path := filepath.Join(cacheDir, "prev_snapshot.json")
	b, err := os.ReadFile(path)
	if err != nil {
		return Snapshot{}, err
	}
	var s Snapshot
	if err := json.Unmarshal(b, &s); err != nil {
		return Snapshot{}, err
	}
	return s, nil
}

// SaveSnapshot persists the current run snapshot
func SaveSnapshot(cacheDir string, s Snapshot) error {
	path := filepath.Join(cacheDir, "prev_snapshot.json")
	_ = os.MkdirAll(cacheDir, 0755)
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	return os.WriteFile(path, b, 0644)
}
