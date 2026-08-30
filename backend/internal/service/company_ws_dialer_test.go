package service

import (
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/stretchr/testify/require"
)

func TestResolveCompanyWebSocketProxyUsesManagedDecision(t *testing.T) {
	proxyID := int64(7)
	account := &Account{
		ID:       3,
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
		ProxyID:  &proxyID,
		Proxy: &Proxy{
			ID:           proxyID,
			Protocol:     "http",
			Host:         "attacker.invalid",
			Port:         8080,
			Status:       StatusActive,
			FallbackMode: FallbackModeNone,
		},
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

	proxyURL, err := resolveCompanyWebSocketProxy(
		t.Context(),
		&config.Config{Server: config.ServerConfig{Mode: "release"}},
		resolver,
		account,
		"wss://api.openai.com/v1/responses",
	)
	require.NoError(t, err)
	require.Equal(t, "socks5h://127.0.0.1:11001", proxyURL)
}

func TestResolveCompanyWebSocketProxyFailsClosed(t *testing.T) {
	account := &Account{ID: 3, Platform: PlatformOpenAI, Type: AccountTypeOAuth}
	_, err := resolveCompanyWebSocketProxy(
		t.Context(),
		&config.Config{Server: config.ServerConfig{Mode: "release"}},
		nil,
		account,
		"wss://api.openai.com/v1/responses",
	)
	require.ErrorIs(t, err, ErrManagedEgressPolicy)
}

func TestOpenAIWSProxyClientUsesProjectSOCKSParser(t *testing.T) {
	dialer, ok := newDefaultOpenAIWSClientDialer().(*coderOpenAIWSClientDialer)
	require.True(t, ok)
	client, err := dialer.proxyHTTPClient("socks5h://127.0.0.1:11001")
	require.NoError(t, err)
	require.NotNil(t, client)

	_, err = dialer.proxyHTTPClient("socks5h://127.0.0.1:not-a-port")
	require.Error(t, err)
}
