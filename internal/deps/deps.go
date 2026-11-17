// Package deps exists only to pin the module's dependency set.
//
// Every dependency OurSync will use is listed here as a blank import, so that `go mod tidy`
// keeps it in go.mod before any real code imports it. That matters because the packages are
// written in parallel: without this, the first `tidy` would drop everything unused and each
// package's author would re-add its own dependencies at whatever version resolved that day.
//
// The rule that goes with it: **do not edit go.mod or go.sum.** Everything needed is already
// required at a pinned version. A new dependency is a decision, not a build step — raise it.
//
// Delete this package once every dependency below is imported by real code.
package deps

import (
	_ "github.com/godbus/dbus/v5"      // Secret Service over D-Bus, so no libsecret via cgo
	_ "golang.org/x/oauth2"            // the OAuth flow and token refresh
	_ "golang.org/x/time/rate"         // the quota-unit limiter and the upload rate cap
	_ "google.golang.org/api/drive/v3" // the first-party generated Drive client
	_ "google.golang.org/api/option"   // client construction
	_ "modernc.org/sqlite"             // pure-Go SQLite: no cgo, so the .deb stays one binary
)
