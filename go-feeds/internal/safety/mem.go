package safety

import (
	"os"
	"strconv"
	"strings"
)

// MemAvail holds available memory info (cgroup-aware)
type MemAvail struct {
	Total         int64
	Avail         int64
	CgroupLimit   int64
	CgroupCurrent int64
}

func readFirstInt64(path string) (int64, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	s := strings.TrimSpace(string(b))
	if s == "max" {
		return 1 << 62, nil // cgroup v2 "no limit"
	}
	return strconv.ParseInt(s, 10, 64)
}

// AvailableMem returns available memory (cgroup-aware for containers)
func AvailableMem() MemAvail {
	// cgroup v2 paths
	mlim, _ := readFirstInt64("/sys/fs/cgroup/memory.max")
	mcur, _ := readFirstInt64("/sys/fs/cgroup/memory.current")

	// /proc/meminfo fallback
	var memTotal, memAvail int64
	if b, err := os.ReadFile("/proc/meminfo"); err == nil {
		lines := strings.Split(string(b), "\n")
		for _, ln := range lines {
			if strings.HasPrefix(ln, "MemTotal:") {
				fields := strings.Fields(ln)
				// kB → bytes
				if len(fields) >= 2 {
					if v, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
						memTotal = v * 1024
					}
				}
			}
			if strings.HasPrefix(ln, "MemAvailable:") {
				fields := strings.Fields(ln)
				if len(fields) >= 2 {
					if v, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
						memAvail = v * 1024
					}
				}
			}
		}
	}

	// if running under cgroup with a smaller limit than host RAM, use that window
	if mlim > 0 && mlim < (1<<61) {
		// avail within cgroup = limit - current (bounded by MemAvailable)
		cgAvail := mlim - mcur
		if cgAvail < 0 {
			cgAvail = 0
		}
		if memAvail == 0 || cgAvail < memAvail {
			memAvail = cgAvail
		}
		memTotal = mlim
	}

	return MemAvail{
		Total:         memTotal,
		Avail:         memAvail,
		CgroupLimit:   mlim,
		CgroupCurrent: mcur,
	}
}
