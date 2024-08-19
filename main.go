package main

import (
	"context"

	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/nomad/plugins"
	"github.com/topmanage/raw_exec_windows/rawexecwindows"
)

func main() {
	// Serve the plugin
	plugins.Serve(factory)
}

// factory returns a new instance of a nomad driver plugin
func factory(log hclog.Logger) interface{} {
	ctx := context.Background()
	return rawexecwindows.NewRawExecWindowsDriver(ctx, log)
}
