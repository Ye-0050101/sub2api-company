package service

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/stretchr/testify/require"
)

func TestProvidePluginManagerDoesNotExposeAccountDirectoryInCompanyMode(t *testing.T) {
	gateway := &OpenAIGatewayService{}
	cfg := &config.Config{
		CompanyEgress: config.CompanyEgressConfig{
			ManagedProxies: []config.CompanyManagedProxyConfig{{
				ProxyID:     10,
				Class:       ManagedProxyClassInternational,
				CountryCode: "US",
			}},
		},
	}

	manager := ProvidePluginManager(nil, nil, cfg, PluginHostInfo{}, nil, gateway)
	require.Nil(t, manager.accountDirectory)

	cfg.CompanyEgress.DevelopmentBypass = true
	development := ProvidePluginManager(nil, nil, cfg, PluginHostInfo{}, nil, gateway)
	require.Same(t, gateway, development.accountDirectory)
}
