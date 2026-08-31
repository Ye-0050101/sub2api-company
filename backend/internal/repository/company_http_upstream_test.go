package repository

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/pkg/tlsfingerprint"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/stretchr/testify/require"
)

type companyResolverStub struct {
	decision service.ManagedProxyDecision
	err      error
	bypass   bool
}

func TestCompanyPrivacyClientRejectsEmptyProxy(t *testing.T) {
	_, err := CreateCompanyPrivacyReqClient("")
	require.Error(t, err)
}

func (s *companyResolverStub) ResolveForAccount(context.Context, int64) (service.ManagedProxyDecision, error) {
	return s.decision, s.err
}

func (s *companyResolverStub) ResolveForProxyID(context.Context, int64, string, string) (service.ManagedProxyDecision, error) {
	return s.decision, s.err
}

func (s *companyResolverStub) DevelopmentBypass() bool { return s.bypass }

type companyRawUpstreamStub struct {
	calls    int
	request  *http.Request
	proxyURL string
}

func (s *companyRawUpstreamStub) Do(req *http.Request, proxyURL string, _ int64, _ int) (*http.Response, error) {
	s.calls++
	s.request = req
	s.proxyURL = proxyURL
	return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("ok"))}, nil
}

func (s *companyRawUpstreamStub) DoWithTLS(req *http.Request, proxyURL string, accountID int64, concurrency int, _ *tlsfingerprint.Profile) (*http.Response, error) {
	return s.Do(req, proxyURL, accountID, concurrency)
}

func TestCompanyHTTPUpstreamOverridesCallerProxyAndDisablesRedirects(t *testing.T) {
	raw := &companyRawUpstreamStub{}
	resolver := &companyResolverStub{decision: service.ManagedProxyDecision{
		Platform: service.PlatformOpenAI,
		ProxyURL: "socks5h://127.0.0.1:11001",
	}}
	upstream, err := NewCompanyHTTPUpstream(RawHTTPUpstream{upstream: raw}, resolver)
	require.NoError(t, err)
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "https://api.openai.com/v1/models", nil)
	require.NoError(t, err)

	_, err = upstream.Do(req, "http://attacker.invalid:8080", 3, 1)
	require.NoError(t, err)
	require.Equal(t, "socks5h://127.0.0.1:11001", raw.proxyURL)
	require.True(t, service.HTTPUpstreamRedirectsDisabled(raw.request.Context()))
}

func TestCompanyHTTPUpstreamRejectsUnapprovedHostBeforeNetwork(t *testing.T) {
	raw := &companyRawUpstreamStub{}
	resolver := &companyResolverStub{decision: service.ManagedProxyDecision{
		Platform: service.PlatformOpenAI,
		ProxyURL: "socks5h://127.0.0.1:11001",
	}}
	upstream, err := NewCompanyHTTPUpstream(RawHTTPUpstream{upstream: raw}, resolver)
	require.NoError(t, err)
	req, err := http.NewRequestWithContext(t.Context(), http.MethodGet, "https://api.openai.com.evil.example/v1/models", nil)
	require.NoError(t, err)

	_, err = upstream.Do(req, "", 3, 1)
	require.ErrorIs(t, err, service.ErrManagedEgressPolicy)
	require.Zero(t, raw.calls)
}
