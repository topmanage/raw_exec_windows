package main

import (
	"context"

	"bitbucket.org/topmanage-software-engineering/nomad-taskdriver-cco/src/cco"
	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/nomad/plugins"
)

func main() {
	// Serve the plugin
	plugins.Serve(factory)
}

// factory returns a new instance of a nomad driver plugin
func factory(log hclog.Logger) interface{} {
	ctx := context.Background()
	return cco.NewCcoDriver(ctx, log)
}
