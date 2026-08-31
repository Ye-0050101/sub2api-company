package service

import (
	"context"
	"errors"
	"net/url"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/stretchr/testify/require"
)

type managedAccountRepositoryStub struct {
	AccountRepository
	accounts map[int64]*Account
	err      error
}

func (s *managedAccountRepositoryStub) GetByID(_ context.Context, id int64) (*Account, error) {
	if s.err != nil {
		return nil, s.err
	}
	return s.accounts[id], nil
}

type managedProxyRepositoryStub struct {
	ProxyRepository
	proxies map[int64]*Proxy
	err     error
}

func (s *managedProxyRepositoryStub) GetByID(_ context.Context, id int64) (*Proxy, error) {
	if s.err != nil {
		return nil, s.err
	}
	return s.proxies[id], nil
}

type managedProxyHealthStub struct {
	epoch uint64
	err   error
}

func (s *managedProxyHealthStub) RequireReady(context.Context, ManagedProxyPolicy, *Proxy, string) (uint64, error) {
	return s.epoch, s.err
}

func managedProxyConfig(proxyID int64) *config.Config {
	return &config.Config{
		CompanyEgress: config.CompanyEgressConfig{
			ManagedProxies: []config.CompanyManagedProxyConfig{{
				ProxyID:          proxyID,
				Class:            ManagedProxyClassInternational,
				CountryCode:      "US",
				ExpectedExitIPv4: "8.8.8.8",
			}},
		},
	}
}

func validManagedProxy(proxyID int64) *Proxy {
	return &Proxy{
		ID:           proxyID,
		Protocol:     "socks5h",
		Host:         "127.0.0.1",
		Port:         11001,
		Status:       StatusActive,
		FallbackMode: FallbackModeNone,
	}
}

func TestNewManagedProxyPoliciesRejectsUnsafeStartupConfig(t *testing.T) {
	t.Run("direct fallback", func(t *testing.T) {
		cfg := managedProxyConfig(7)
		cfg.Security.ProxyFallback.AllowDirectOnError = true
		_, err := NewManagedProxyPolicies(cfg)
		require.ErrorIs(t, err, ErrManagedEgressPolicy)
	})

	t.Run("release bypass", func(t *testing.T) {
		cfg := managedProxyConfig(7)
		cfg.Server.Mode = "release"
		cfg.CompanyEgress.DevelopmentBypass = true
		_, err := NewManagedProxyPolicies(cfg)
		require.ErrorIs(t, err, ErrManagedEgressPolicy)
	})

	t.Run("duplicate proxy id", func(t *testing.T) {
		cfg := managedProxyConfig(7)
		cfg.CompanyEgress.ManagedProxies = append(cfg.CompanyEgress.ManagedProxies, cfg.CompanyEgress.ManagedProxies[0])
		_, err := NewManagedProxyPolicies(cfg)
		require.ErrorIs(t, err, ErrManagedEgressPolicy)
	})

	t.Run("Grok password auth", func(t *testing.T) {
		cfg := managedProxyConfig(7)
		cfg.Gateway.Grok.PasswordAuthEnabled = true
		_, err := NewManagedProxyPolicies(cfg)
		require.ErrorIs(t, err, ErrManagedEgressPolicy)
	})

	t.Run("Gemini batch", func(t *testing.T) {
		cfg := managedProxyConfig(7)
		cfg.BatchImage.Enabled = true
		_, err := NewManagedProxyPolicies(cfg)
		require.ErrorIs(t, err, ErrManagedEgressPolicy)
	})
}

func TestValidateManagedProxyFailsClosed(t *testing.T) {
	policy := ManagedProxyPolicy{ProxyID: 7}
	tests := []struct {
		name   string
		mutate func(*Proxy)
	}{
		{name: "inactive", mutate: func(proxy *Proxy) { proxy.Status = "inactive" }},
		{name: "non loopback", mutate: func(proxy *Proxy) { proxy.Host = "8.8.8.8" }},
		{name: "hostname", mutate: func(proxy *Proxy) { proxy.Host = "localhost" }},
		{name: "socks5 alias", mutate: func(proxy *Proxy) { proxy.Protocol = "socks5" }},
		{name: "credentials", mutate: func(proxy *Proxy) { proxy.Username, proxy.Password = "u", "p" }},
		{name: "direct fallback", mutate: func(proxy *Proxy) { proxy.FallbackMode = FallbackModeDirect }},
		{name: "backup", mutate: func(proxy *Proxy) { id := int64(8); proxy.BackupProxyID = &id }},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			proxy := validManagedProxy(7)
			tt.mutate(proxy)
			require.ErrorIs(t, ValidateManagedProxy(policy, proxy), ErrManagedEgressPolicy)
		})
	}
}

func TestManagedProxyResolverUsesOnlyConfiguredProxyID(t *testing.T) {
	proxyID := int64(7)
	policies, err := NewManagedProxyPolicies(managedProxyConfig(proxyID))
	require.NoError(t, err)
	account := &Account{ID: 3, Platform: PlatformOpenAI, Type: AccountTypeOAuth, ProxyID: &proxyID}
	proxy := validManagedProxy(proxyID)
	resolver, err := NewManagedProxyResolver(
		&managedAccountRepositoryStub{accounts: map[int64]*Account{account.ID: account}},
		&managedProxyRepositoryStub{proxies: map[int64]*Proxy{proxyID: proxy}},
		policies,
		&managedProxyHealthStub{epoch: 4},
	)
	require.NoError(t, err)

	decision, err := resolver.ResolveForAccount(t.Context(), account.ID)
	require.NoError(t, err)
	require.Equal(t, proxyID, decision.ProxyID)
	require.Equal(t, "socks5h://127.0.0.1:11001", decision.ProxyURL)
	require.Equal(t, uint64(4), decision.HealthEpoch)
}

func TestManagedProxyResolverRejectsUnsupportedAndSoftDeletedProxy(t *testing.T) {
	proxyID := int64(7)
	policies, err := NewManagedProxyPolicies(managedProxyConfig(proxyID))
	require.NoError(t, err)
	proxy := validManagedProxy(proxyID)

	unsupported := &Account{ID: 1, Platform: PlatformAntigravity, Type: AccountTypeOAuth, ProxyID: &proxyID}
	resolver, err := NewManagedProxyResolver(
		&managedAccountRepositoryStub{accounts: map[int64]*Account{unsupported.ID: unsupported}},
		&managedProxyRepositoryStub{proxies: map[int64]*Proxy{proxyID: proxy}},
		policies,
		&managedProxyHealthStub{epoch: 1},
	)
	require.NoError(t, err)
	_, err = resolver.ResolveForAccount(t.Context(), unsupported.ID)
	require.ErrorIs(t, err, ErrManagedEgressUnsupported)

	softDeletedRepo := &managedProxyRepositoryStub{proxies: map[int64]*Proxy{proxyID: proxy}}
	resolver, err = NewManagedProxyResolver(
		&managedAccountRepositoryStub{accounts: map[int64]*Account{}},
		softDeletedRepo,
		policies,
		&managedProxyHealthStub{epoch: 1},
	)
	require.NoError(t, err)
	softDeletedRepo.err = errors.New("proxy not found")
	_, err = resolver.ResolveForProxyID(t.Context(), proxyID, PlatformOpenAI, AccountTypeOAuth)
	require.ErrorIs(t, err, ErrManagedEgressPolicy)
}

func TestManagedProxyResolverRejectsOpenAIEdgeAuthModes(t *testing.T) {
	proxyID := int64(7)
	for _, mode := range []string{OpenAIAuthModePersonalAccessToken, OpenAIAuthModeAgentIdentity} {
		account := &Account{
			ID:          10,
			Platform:    PlatformOpenAI,
			Type:        AccountTypeOAuth,
			ProxyID:     &proxyID,
			Credentials: map[string]any{openAIAuthModeCredentialKey: mode},
		}
		policies, err := NewManagedProxyPolicies(managedProxyConfig(proxyID))
		require.NoError(t, err)
		resolver, err := NewManagedProxyResolver(
			&managedAccountRepositoryStub{accounts: map[int64]*Account{account.ID: account}},
			&managedProxyRepositoryStub{proxies: map[int64]*Proxy{proxyID: validManagedProxy(proxyID)}},
			policies,
			&managedProxyHealthStub{epoch: 1},
		)
		require.NoError(t, err)
		_, err = resolver.ResolveForAccount(t.Context(), account.ID)
		require.ErrorIs(t, err, ErrManagedEgressUnsupported, mode)
	}
}

func TestValidateManagedDestinationExactHTTPSOnly(t *testing.T) {
	decision := ManagedProxyDecision{Platform: PlatformOpenAI}
	for _, raw := range []string{
		"https://api.openai.com/v1/responses",
		"https://API.OPENAI.COM./v1/responses",
		"https://api.openai.com:443/v1/responses",
	} {
		target, err := url.Parse(raw)
		require.NoError(t, err)
		require.NoError(t, ValidateManagedDestination(decision, target, false), raw)
	}
	for _, raw := range []string{
		"http://api.openai.com/v1/responses",
		"https://api.openai.com:8443/v1/responses",
		"https://evil.api.openai.com/v1/responses",
		"https://api.openai.com.evil.example/v1/responses",
		"https://user@api.openai.com/v1/responses",
	} {
		target, err := url.Parse(raw)
		require.NoError(t, err)
		require.ErrorIs(t, ValidateManagedDestination(decision, target, false), ErrManagedEgressPolicy, raw)
	}
}

func TestManagedCustomBaseURLPolicy(t *testing.T) {
	approved := &Account{
		Platform:    PlatformOpenAI,
		Type:        AccountTypeAPIKey,
		Credentials: map[string]any{"base_url": "https://api.openai.com/v1"},
	}
	require.False(t, managedCustomBaseURLConfigured(approved))

	custom := &Account{
		Platform:    PlatformOpenAI,
		Type:        AccountTypeAPIKey,
		Credentials: map[string]any{"base_url": "https://relay.example/v1"},
	}
	require.True(t, managedCustomBaseURLConfigured(custom))

	geminiDaily, err := url.Parse("https://daily-cloudcode-pa.googleapis.com/v1internal")
	require.NoError(t, err)
	require.ErrorIs(
		t,
		ValidateManagedDestination(ManagedProxyDecision{Platform: PlatformGemini}, geminiDaily, false),
		ErrManagedEgressPolicy,
	)
}

func TestManagedOAuthCallbackRequiresProxyID(t *testing.T) {
	_, err := managedOAuthCallbackDecision(t.Context(), nil, "socks5h://127.0.0.1:11001", nil, PlatformOpenAI, AccountTypeOAuth)
	require.ErrorIs(t, err, ErrManagedEgressPolicy)

	proxyID := int64(7)
	policies, err := NewManagedProxyPolicies(managedProxyConfig(proxyID))
	require.NoError(t, err)
	resolver, err := NewManagedProxyResolver(
		&managedAccountRepositoryStub{accounts: map[int64]*Account{}},
		&managedProxyRepositoryStub{proxies: map[int64]*Proxy{proxyID: validManagedProxy(proxyID)}},
		policies,
		&managedProxyHealthStub{epoch: 1},
	)
	require.NoError(t, err)

	_, err = managedOAuthCallbackDecision(t.Context(), resolver, "socks5h://127.0.0.1:12001", &proxyID, PlatformOpenAI, AccountTypeOAuth)
	require.ErrorIs(t, err, ErrManagedEgressPolicy)

	decision, err := managedOAuthCallbackDecision(t.Context(), resolver, "socks5h://127.0.0.1:11001", &proxyID, PlatformOpenAI, AccountTypeOAuth)
	require.NoError(t, err)
	require.Equal(t, proxyID, decision.ProxyID)
}

func TestCanonicalPublicIPv4(t *testing.T) {
	ip, err := CanonicalPublicIPv4("8.8.8.8")
	require.NoError(t, err)
	require.Equal(t, "8.8.8.8", ip)
	for _, raw := range []string{
		"127.0.0.1", "10.0.0.1", "100.64.0.1", "169.254.1.1", "192.0.2.1",
		"198.51.100.1", "203.0.113.1", "224.0.0.1", "2001:db8::1", "008.008.008.008",
	} {
		_, err := CanonicalPublicIPv4(raw)
		require.Error(t, err, raw)
	}
}
