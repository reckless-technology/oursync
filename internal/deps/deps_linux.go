//go:build linux

package deps

import (
	_ "github.com/hanwen/go-fuse/v2/fs"   // the FUSE node API
	_ "github.com/hanwen/go-fuse/v2/fuse" // the server, notifications and passthrough
	_ "golang.org/x/sys/unix"             // fallocate, SEEK_DATA, statfs
)
