package repository

import (
	"context"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

type companyRawProxyRepositoryStub struct {
	service.ProxyRepository
	updateCalls int
	deleteCalls int
}

func (s *companyRawProxyRepositoryStub) Update(context.Context, *service.Proxy) error {
	s.updateCalls++
	return nil
}

func (s *companyRawProxyRepositoryStub) Delete(context.Context, int64) error {
	s.deleteCalls++
	return nil
}

func TestCompanyProxyRepositoryProtectsManagedProxy(t *testing.T) {
	policies, err := service.NewManagedProxyPolicies(&config.Config{
		CompanyEgress: config.CompanyEgressConfig{ManagedProxies: []config.CompanyManagedProxyConfig{{
			ProxyID:          7,
			Class:            service.ManagedProxyClassInternational,
			CountryCode:      "US",
			ExpectedExitIPv4: "8.8.8.8",
		}}},
	})
	require.NoError(t, err)
	raw := &companyRawProxyRepositoryStub{}
	repo := NewCompanyProxyRepository(RawProxyRepository{ProxyRepository: raw}, policies)

	require.ErrorIs(t, repo.Update(t.Context(), &service.Proxy{ID: 7}), ErrCompanyManagedProxyReadOnly)
	require.ErrorIs(t, repo.Delete(t.Context(), 7), ErrCompanyManagedProxyReadOnly)
	require.Zero(t, raw.updateCalls)
	require.Zero(t, raw.deleteCalls)

	require.NoError(t, repo.Update(t.Context(), &service.Proxy{ID: 8}))
	require.NoError(t, repo.Delete(t.Context(), 8))
	require.Equal(t, 1, raw.updateCalls)
	require.Equal(t, 1, raw.deleteCalls)
}
