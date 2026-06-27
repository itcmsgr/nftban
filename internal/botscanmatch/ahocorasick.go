// SPDX-License-Identifier: MPL-2.0
// meta:name="botscanmatch_ahocorasick" meta:type="package" meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:inventory.files="ahocorasick.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
//
// Compact byte-level Aho-Corasick automaton: match all literal anchors in a single pass
// over each line. Internal implementation — no external dependency. Bounded memory: one
// node per distinct anchor prefix-byte; goto via per-node child maps; fail links via BFS.

package botscanmatch

import "errors"

var errNoUsablePatterns = errors.New("botscanmatch: no usable patterns")

type acNode struct {
	children map[byte]int // byte -> node index
	fail     int          // fail link (node index)
	output   []int        // pattern ids whose anchor ENDS at this node
}

type ahoCorasick struct {
	nodes []acNode
}

func newAhoCorasick() *ahoCorasick {
	return &ahoCorasick{nodes: []acNode{{children: map[byte]int{}}}} // node 0 = root
}

// add inserts a literal anchor mapped to a pattern id.
func (a *ahoCorasick) add(anchor string, id int) {
	cur := 0
	for i := 0; i < len(anchor); i++ {
		b := anchor[i]
		nx, ok := a.nodes[cur].children[b]
		if !ok {
			nx = len(a.nodes)
			a.nodes = append(a.nodes, acNode{children: map[byte]int{}})
			a.nodes[cur].children[b] = nx
		}
		cur = nx
	}
	a.nodes[cur].output = append(a.nodes[cur].output, id)
}

// build computes fail links and merges outputs along fail chains (BFS).
func (a *ahoCorasick) build() {
	queue := make([]int, 0, len(a.nodes))
	for _, nx := range a.nodes[0].children {
		a.nodes[nx].fail = 0
		queue = append(queue, nx)
	}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		for b, nx := range a.nodes[cur].children {
			// fail link for child nx
			f := a.nodes[cur].fail
			for f != 0 {
				if _, ok := a.nodes[f].children[b]; ok {
					break
				}
				f = a.nodes[f].fail
			}
			if fc, ok := a.nodes[f].children[b]; ok && fc != nx {
				a.nodes[nx].fail = fc
			} else {
				a.nodes[nx].fail = 0
			}
			// merge outputs from fail target (so a suffix-anchor also reports)
			a.nodes[nx].output = append(a.nodes[nx].output, a.nodes[a.nodes[nx].fail].output...)
			queue = append(queue, nx)
		}
	}
}

// scan runs the automaton over text. For each anchor occurrence, visit(id) is called for every
// pattern id at that node; if visit returns false, scanning stops early.
func (a *ahoCorasick) scan(text []byte, visit func(id int) bool) {
	cur := 0
	for i := 0; i < len(text); i++ {
		b := text[i]
		for {
			if nx, ok := a.nodes[cur].children[b]; ok {
				cur = nx
				break
			}
			if cur == 0 {
				break
			}
			cur = a.nodes[cur].fail
		}
		for _, id := range a.nodes[cur].output {
			if !visit(id) {
				return
			}
		}
	}
}
