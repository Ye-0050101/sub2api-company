package repository

import (
	"context"
	"testing"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

type companyHealthProxyRepoStub struct {
	service.ProxyRepository
	proxy *service.Proxy
}

func (s *companyHealthProxyRepoStub) GetByID(context.Context, int64) (*service.Proxy, error) {
	return s.proxy, nil
}

func companyHealthFixture(t *testing.T) (*companyManagedProxyHealth, service.ManagedProxyPolicy, *service.Proxy, string) {
	t.Helper()
	proxy := &service.Proxy{
		ID:           7,
		Protocol:     "socks5h",
		Host:         "127.0.0.1",
		Port:         11001,
		Status:       service.StatusActive,
		FallbackMode: service.FallbackModeNone,
	}
	policies, err := service.NewManagedProxyPolicies(&config.Config{
		CompanyEgress: config.CompanyEgressConfig{
			ManagedProxies: []config.CompanyManagedProxyConfig{{
				ProxyID:          7,
				Class:            service.ManagedProxyClassInternational,
				CountryCode:      "US",
				ExpectedExitIPv4: "8.8.8.8",
			}},
		},
	})
	require.NoError(t, err)
	policy := policies.Entries()[0]
	fingerprint := service.ManagedProxyFingerprint(policy, proxy)
	health := &companyManagedProxyHealth{
		states:       make(map[managedProxyHealthKey]managedProxyHealthState),
		fingerprints: map[int64]string{policy.ProxyID: fingerprint},
		policies:     policies,
		proxies:      &companyHealthProxyRepoStub{proxy: proxy},
		now:          time.Now,
	}
	return health, policy, proxy, fingerprint
}

func TestCompanyManagedProxyHealthExpiredFailsClosed(t *testing.T) {
	health, policy, proxy, fingerprint := companyHealthFixture(t)
	key := managedProxyHealthKey{proxyID: policy.ProxyID, fingerprint: fingerprint}
	health.states[key] = managedProxyHealthState{
		ready:     true,
		checkedAt: time.Now().Add(-service.ManagedProxyHealthTTL),
		epoch:     4,
	}

	_, err := health.RequireReady(t.Context(), policy, proxy, fingerprint)
	require.ErrorContains(t, err, "expired")
}

func TestCompanyManagedProxyHealthRejectsExitMismatch(t *testing.T) {
	_, policy, _, _ := companyHealthFixture(t)
	require.ErrorContains(t, validateCompanyExitEvidence(policy, companyExitEvidence{
		ipA:         "13.52.180.166",
		ipB:         "13.52.180.166",
		countryCode: "US",
	}), "IPv4 mismatch")
	require.ErrorContains(t, validateCompanyExitEvidence(policy, companyExitEvidence{
		ipA:         "8.8.8.8",
		ipB:         "8.8.8.8",
		countryCode: "SG",
	}), "country mismatch")
}
