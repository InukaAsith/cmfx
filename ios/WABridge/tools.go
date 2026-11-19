//go:build tools

// gomobile bind needs golang.org/x/mobile/bind in the module (pinned in go.mod with the gomobile CI installs).
package wabridge

import _ "golang.org/x/mobile/bind"
