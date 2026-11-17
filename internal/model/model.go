// Package model holds the types every other package shares, and nothing else.
//
// It has no dependencies beyond the standard library on purpose: it is the contract between the
// store, the Drive client, the cache, the scheduler and the filesystem layer, and a contract that
// imports things grows opinions. Behaviour belongs in the packages that own it; what lives here is
// data, the handful of predicates that are properties of the data itself, and the error values
// callers switch on.
package model

import (
	"errors"
	"strings"
	"time"
)

// AccountID is the user's own label for a Google account, such as "personal" or "work". It names
// the account's database, its cache directory and its mount point, so it is restricted to
// characters that are safe in a path: see ValidAccountID.
type AccountID string

// FileID is a Drive file id. It is the canonical identity of everything in Drive — paths are not,
// because a folder may hold two files of the same name. Never derive one from a path.
type FileID string

// DriveID identifies a shared drive. The empty value means the account's own My Drive.
type DriveID string

// Ino is the inode number OurSync presents to the kernel. Allocated by the store and stored, never
// derived from a FileID: a hash would collide, and a collision here is data corruption rather than
// a glitch.
type Ino uint64

// Drive's own MIME types that mean something structural to us.
const (
	MIMEFolder   = "application/vnd.google-apps.folder"
	MIMEShortcut = "application/vnd.google-apps.shortcut"

	// nativePrefix covers every Google-native type: Docs, Sheets, Slides, Drawings, Forms and the
	// rest. They have no byte stream, so they can neither be range-read nor written back.
	nativePrefix = "application/vnd.google-apps."
)

// Node is one entry in a Drive tree, as OurSync stores it.
type Node struct {
	ID       FileID
	DriveID  DriveID // empty for My Drive
	ParentID FileID  // empty for a root

	// Name is Drive's name, verbatim, including anything POSIX-hostile: a slash, a trailing dot, a
	// duplicate of a sibling's name. LocalName is what the filesystem presents, computed once when
	// the node is ingested and then stored. The mapping is not injective, so the only correct way
	// to go from LocalName back to a node is a lookup by (ParentID, LocalName).
	Name      string
	LocalName string

	Ino Ino

	MIME string

	// Size is meaningful only when HasSize is set. Drive reports no size for folders and shortcuts,
	// and reports an unreliable one for native documents, so a plain int64 would quietly present
	// "unknown" as "empty".
	Size    int64
	HasSize bool

	// MD5 is Drive's md5Checksum, present for binary content and absent for native documents and
	// shortcuts. It is how the write path decides whether an upload can be skipped entirely, and
	// how the read path decides a cached range is still valid.
	MD5 string

	// Version is Drive's monotonic version counter, which moves on every server-side change
	// including ones the user cannot see. It is the cheap "has this changed" test; MD5 is the
	// expensive, content-accurate one.
	Version int64

	ModifiedTime time.Time
	Trashed      bool

	// ShortcutTarget is set only on a shortcut, and may name a file we cannot see — a shortcut to a
	// deleted or unshared target, which is presented as a dangling symlink.
	ShortcutTarget FileID
}

// IsFolder reports whether the node is a Drive folder.
func (n Node) IsFolder() bool { return n.MIME == MIMEFolder }

// IsShortcut reports whether the node is a Drive shortcut, which OurSync presents as a symlink.
func (n Node) IsShortcut() bool { return n.MIME == MIMEShortcut }

// IsNative reports whether the node is a Google-native document — a Doc, Sheet, Slide, Drawing or
// any other application/vnd.google-apps type that is not a folder or a shortcut. These have no byte
// stream: they cannot be range-read, cannot be written back, and are presented as stub files or as
// a capped export.
func (n Node) IsNative() bool {
	return strings.HasPrefix(n.MIME, nativePrefix) && !n.IsFolder() && !n.IsShortcut()
}

// IsStreamable reports whether the node has content OurSync can fetch by byte range.
func (n Node) IsStreamable() bool { return !n.IsFolder() && !n.IsShortcut() && !n.IsNative() }

// PinMode is a node's availability policy, inherited by descendants unless overridden.
type PinMode string

const (
	// PinOnline is the default: visible, streamed on demand, and its cache is evictable.
	PinOnline PinMode = "online"
	// PinOffline is "available offline": hydrated eagerly, kept hydrated, never evicted, and
	// accounted outside the cache budget because it is not a cache.
	PinOffline PinMode = "offline"
	// PinExcluded hides the subtree from the filesystem entirely. Its metadata is still tracked, so
	// the change feed stays consistent, but it occupies no space and is not listed.
	PinExcluded PinMode = "excluded"
)

// Valid reports whether p is one of the three known modes.
func (p PinMode) Valid() bool {
	switch p {
	case PinOnline, PinOffline, PinExcluded:
		return true
	}
	return false
}

// Quota is the account's storage usage, from Drive's about.get.
type Quota struct {
	// Limit is zero when the account has no limit (Drive omits the field, which must not be read
	// as "no space left").
	Limit        int64
	HasLimit     bool
	Usage        int64 // across all Google services
	UsageInDrive int64
	UsageInTrash int64
}

// Change is one entry from Drive's change feed. The feed carries each file's current state rather
// than a diff, so applying a change is an upsert and applying one twice is harmless.
type Change struct {
	FileID  FileID
	DriveID DriveID
	Time    time.Time
	// Removed means the file was deleted or access to it was lost. Node is then not populated.
	Removed bool
	Node    Node
}

// ChangePage is one page of the change feed.
type ChangePage struct {
	Changes []Change
	// NextPageToken is set while more pages remain. NewStartPageToken is set on the last page only,
	// and is the token to persist — but only once every change in the page has been applied, in the
	// same transaction, or changes are lost silently on a crash.
	NextPageToken     string
	NewStartPageToken string
}

// The errors callers switch on. Packages wrap these with context; callers compare with errors.Is.
var (
	// ErrNotFound means no such node, account, or cached range.
	ErrNotFound = errors.New("not found")

	// ErrAuthExpired means the refresh token is dead — revoked, unused for six months, or expired
	// because the Cloud app is in Testing status. The mount stays up and read-only from cache; the
	// repair is re-running the consent flow.
	ErrAuthExpired = errors.New("authorisation expired")

	// ErrStorageQuota is Drive's storageQuotaExceeded: the account is full. Terminal, never retried.
	ErrStorageQuota = errors.New("drive storage quota exceeded")

	// ErrDownloadQuota is Drive's downloadQuotaExceeded — undocumented but real, and per file
	// rather than per account. It clears on its own after roughly a day.
	ErrDownloadQuota = errors.New("per-file download quota exceeded")

	// ErrAbusive means Drive has flagged the file and will only serve it with acknowledgeAbuse,
	// which only its owner may set. The user is asked rather than it being set silently.
	ErrAbusive = errors.New("file flagged as abusive; download needs acknowledgement")

	// ErrNotOwner means the operation needs ownership the user does not have — most often trashing
	// a file someone else owns, which Drive refuses outright.
	ErrNotOwner = errors.New("operation requires ownership")

	// ErrNotStreamable means the node has no byte stream: a native Google document, a folder or a
	// shortcut.
	ErrNotStreamable = errors.New("node has no byte content")

	// ErrExportTooLarge means a native document exceeds Drive's 10 MB export cap, so it cannot be
	// presented as an exported file at all.
	ErrExportTooLarge = errors.New("native document exceeds the 10 MB export limit")

	// ErrRateLimited is a retryable rate-limit refusal (403 rateLimitExceeded,
	// 403 userRateLimitExceeded or 429). The transport retries these; it reaches a caller only when
	// the retries are exhausted.
	ErrRateLimited = errors.New("rate limited")
)

// ValidAccountID reports whether s is usable as an account label. An account label becomes a path
// component in three places — the database directory, the cache directory and the mount point — so
// it is deliberately narrow: one to 32 characters of ASCII letters, digits, hyphen or underscore,
// not starting with a hyphen. Anything else is rejected at the point the account is added, where
// the user can simply pick another, rather than escaped and smuggled into a path.
func ValidAccountID(s string) bool {
	if len(s) == 0 || len(s) > 32 || s[0] == '-' {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '_':
		default:
			return false
		}
	}
	return true
}
