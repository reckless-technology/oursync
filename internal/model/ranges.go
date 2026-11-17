package model

import (
	"fmt"
	"sort"
	"strings"
)

// ByteRange is a half-open interval of a file, [Start, End). Half-open throughout: it makes an
// empty range representable without a special case, makes adjacency a simple equality
// (a.End == b.Start), and avoids the off-by-one that inclusive ends invite. Drive's HTTP Range
// header is inclusive, so converting at that boundary — and only there — is the Drive client's job.
type ByteRange struct {
	Start int64
	End   int64
}

// Len is the number of bytes in the range, or zero if it is empty or inverted.
func (r ByteRange) Len() int64 {
	if r.End <= r.Start {
		return 0
	}
	return r.End - r.Start
}

// Empty reports whether the range holds no bytes.
func (r ByteRange) Empty() bool { return r.End <= r.Start }

// Contains reports whether off is one of the range's bytes.
func (r ByteRange) Contains(off int64) bool { return off >= r.Start && off < r.End }

// Overlaps reports whether the two ranges share at least one byte. Adjacent ranges do not overlap.
func (r ByteRange) Overlaps(o ByteRange) bool {
	if r.Empty() || o.Empty() {
		return false
	}
	return r.Start < o.End && o.Start < r.End
}

// Intersect returns the bytes the two ranges share, which may be empty.
func (r ByteRange) Intersect(o ByteRange) ByteRange {
	s, e := r.Start, r.End
	if o.Start > s {
		s = o.Start
	}
	if o.End < e {
		e = o.End
	}
	if e <= s {
		return ByteRange{}
	}
	return ByteRange{Start: s, End: e}
}

func (r ByteRange) String() string { return fmt.Sprintf("[%d,%d)", r.Start, r.End) }

// RangeSet is the set of byte ranges of a file that the cache actually holds.
//
// It exists because a hole in a sparse cache file is indistinguishable from real zero bytes in the
// file's content, so the file on disk can never be asked what it contains. This set is the
// authority, it is persisted alongside the cache file, and reading a byte it does not cover means
// fetching that byte. Getting this type wrong serves zeros as data, which is the exact failure the
// whole design is built to avoid — hence the invariant checks and the fuzz target beside it.
//
// The invariant, maintained by every method: ranges are non-empty, sorted by Start, and neither
// overlapping nor adjacent, so the representation of a given set of bytes is unique.
type RangeSet struct {
	rs []ByteRange
}

// NewRangeSet builds a set from arbitrary ranges, normalising them: empty ones are dropped, and
// overlapping or adjacent ones are merged.
func NewRangeSet(ranges ...ByteRange) RangeSet {
	var s RangeSet
	for _, r := range ranges {
		s.Add(r)
	}
	return s
}

// Ranges returns the set's ranges in order, as a copy the caller may keep.
func (s RangeSet) Ranges() []ByteRange {
	if len(s.rs) == 0 {
		return nil
	}
	out := make([]ByteRange, len(s.rs))
	copy(out, s.rs)
	return out
}

// Bytes is the total number of bytes the set covers.
func (s RangeSet) Bytes() int64 {
	var n int64
	for _, r := range s.rs {
		n += r.Len()
	}
	return n
}

// Add inserts a range, merging it with anything it overlaps or abuts.
func (s *RangeSet) Add(r ByteRange) {
	if r.Empty() {
		return
	}
	// The first range that could touch r is the first whose End is at or past r.Start: anything
	// ending before r.Start is strictly to the left with a gap, so it stays put.
	i := sort.Search(len(s.rs), func(i int) bool { return s.rs[i].End >= r.Start })

	// Absorb every range from i that touches r, widening r as we go.
	j := i
	for j < len(s.rs) && s.rs[j].Start <= r.End {
		if s.rs[j].Start < r.Start {
			r.Start = s.rs[j].Start
		}
		if s.rs[j].End > r.End {
			r.End = s.rs[j].End
		}
		j++
	}

	// Replace [i, j) with the single merged range.
	switch {
	case i == j:
		s.rs = append(s.rs, ByteRange{})
		copy(s.rs[i+1:], s.rs[i:])
		s.rs[i] = r
	default:
		s.rs[i] = r
		if j > i+1 {
			s.rs = append(s.rs[:i+1], s.rs[j:]...)
		}
	}
}

// Remove deletes a range of bytes from the set, splitting a covering range in two where the removal
// falls in its middle. This is eviction: the caller punches the same hole in the cache file.
func (s *RangeSet) Remove(r ByteRange) {
	if r.Empty() || len(s.rs) == 0 {
		return
	}
	out := make([]ByteRange, 0, len(s.rs)+1)
	for _, have := range s.rs {
		if !have.Overlaps(r) {
			out = append(out, have)
			continue
		}
		if have.Start < r.Start {
			out = append(out, ByteRange{Start: have.Start, End: r.Start})
		}
		if have.End > r.End {
			out = append(out, ByteRange{Start: r.End, End: have.End})
		}
	}
	if len(out) == 0 {
		s.rs = nil
		return
	}
	s.rs = out
}

// Covers reports whether every byte of r is in the set. An empty range is covered trivially.
func (s RangeSet) Covers(r ByteRange) bool {
	if r.Empty() {
		return true
	}
	i := sort.Search(len(s.rs), func(i int) bool { return s.rs[i].End > r.Start })
	if i == len(s.rs) {
		return false
	}
	return s.rs[i].Start <= r.Start && s.rs[i].End >= r.End
}

// CoversWhole reports whether the set covers a file of the given size entirely, which is the test
// for whether a cached file may be handed to the kernel as a passthrough backing file. A zero-length
// file is covered by the empty set: there are no bytes to be missing.
func (s RangeSet) CoversWhole(size int64) bool {
	if size <= 0 {
		return true
	}
	return s.Covers(ByteRange{Start: 0, End: size})
}

// Missing returns the parts of r that the set does not hold, in order — exactly what has to be
// fetched to satisfy a read of r. The returned ranges are non-empty, disjoint and within r.
func (s RangeSet) Missing(r ByteRange) []ByteRange {
	if r.Empty() {
		return nil
	}
	var out []ByteRange
	at := r.Start
	i := sort.Search(len(s.rs), func(i int) bool { return s.rs[i].End > r.Start })
	for ; i < len(s.rs) && at < r.End; i++ {
		have := s.rs[i]
		if have.Start >= r.End {
			break
		}
		if have.Start > at {
			out = append(out, ByteRange{Start: at, End: min64(have.Start, r.End)})
		}
		if have.End > at {
			at = have.End
		}
	}
	if at < r.End {
		out = append(out, ByteRange{Start: at, End: r.End})
	}
	return out
}

func (s RangeSet) String() string {
	if len(s.rs) == 0 {
		return "{}"
	}
	parts := make([]string, len(s.rs))
	for i, r := range s.rs {
		parts[i] = r.String()
	}
	return "{" + strings.Join(parts, " ") + "}"
}

// Invariant returns an error describing the first way in which the set is malformed, or nil. It is
// exported so tests, the fuzz target and the store's load path can all assert the same property:
// the store reads these ranges back from SQLite, and a set that arrives malformed from disk would
// otherwise be trusted.
func (s RangeSet) Invariant() error {
	for i, r := range s.rs {
		if r.Empty() {
			return fmt.Errorf("range %d of %d is empty: %v", i, len(s.rs), r)
		}
		if i == 0 {
			continue
		}
		prev := s.rs[i-1]
		if r.Start < prev.End {
			return fmt.Errorf("range %d %v overlaps its predecessor %v", i, r, prev)
		}
		if r.Start == prev.End {
			return fmt.Errorf("range %d %v is adjacent to its predecessor %v and should have merged", i, r, prev)
		}
	}
	return nil
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
