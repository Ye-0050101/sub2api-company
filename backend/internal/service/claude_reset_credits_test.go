package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type resetAccountStub struct{ account *Account }

func (s resetAccountStub) GetByID(context.Context, int64) (*Account, error) { return s.account, nil }

type resetTokenStub struct{}

func (resetTokenStub) GetAccessToken(context.Context, *Account) (string, error) {
	return "synthetic-token", nil
}

type resetManagedResolverStub struct {
	decision ManagedProxyDecision
	err      error
	calls    int
}

func (s *resetManagedResolverStub) ResolveForAccount(context.Context, int64) (ManagedProxyDecision, error) {
	s.calls++
	return s.decision, s.err
}

func (s *resetManagedResolverStub) ResolveForProxyID(context.Context, int64, string, string) (ManagedProxyDecision, error) {
	return ManagedProxyDecision{}, errors.New("unexpected proxy-id resolution")
}

func (s *resetManagedResolverStub) DevelopmentBypass() bool { return false }

func TestCompanyClaudeResetUsesManagedProxyAndFailsClosed(t *testing.T) {
	account := &Account{ID: 9, Platform: PlatformAnthropic, Type: AccountTypeOAuth, Credentials: map[string]any{"scope": "user:profile"}}
	resolver := &resetManagedResolverStub{decision: ManagedProxyDecision{ProxyURL: "socks5h://127.0.0.1:11000"}}
	s := &ClaudeResetCreditService{accounts: resetAccountStub{account}, tokens: resetTokenStub{}}
	s.SetManagedProxyResolver(resolver)
	_, token, proxyURL, err := s.account(context.Background(), account.ID)
	require.NoError(t, err)
	require.Equal(t, "synthetic-token", token)
	require.Equal(t, "socks5h://127.0.0.1:11000", proxyURL)
	require.Equal(t, 1, resolver.calls)

	resolver.err = ErrManagedEgressNotReady
	_, _, _, err = s.account(context.Background(), account.ID)
	require.ErrorIs(t, err, ErrManagedEgressNotReady)
	require.Equal(t, 2, resolver.calls)
}

func TestClaudeResetStatusNativeContract(t *testing.T) {
	now := time.Date(2026, 9, 25, 0, 0, 0, 0, time.UTC)
	s := &ClaudeResetCreditService{accounts: resetAccountStub{&Account{ID: 1, Platform: PlatformAnthropic, Type: AccountTypeOAuth, Credentials: map[string]any{"scope": "user:profile user:inference"}}}, tokens: resetTokenStub{}, now: func() time.Time { return now }}
	s.do = func(r *http.Request, p string) (*http.Response, error) {
		require.Equal(t, claudeResetUsageURL, r.URL.String())
		require.Equal(t, "GET", r.Method)
		require.Equal(t, "Bearer synthetic-token", r.Header.Get("Authorization"))
		require.Contains(t, r.Header.Get("User-Agent"), "claude-cli/")
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(`{"cedar_ember":{"eligible":true,"at_limit":false,"next_grant_id":"launch","grants":[{"id":"launch","resets_left":2,"usable_now":true,"use_requires_limit":false,"ends_at":"2026-10-22T00:00:00Z","clears":["five_hour"],"percent_used":{"five_hour":65},"blocking":[]},{"id":"later","clears":["five_hour"],"resets_left":1,"usable_now":true,"use_requires_limit":false}]}}`))}, nil
	}
	r, e := s.Query(context.Background(), 1)
	require.NoError(t, e)
	require.Equal(t, 2, r.AvailableCount)
	require.True(t, r.Credits[0].Redeemable)
	require.False(t, r.Credits[1].Redeemable)
	b, e := json.Marshal(r)
	require.NoError(t, e)
	require.NotContains(t, string(b), `"id"`)
	require.NotContains(t, string(b), "launch")
	require.NotContains(t, string(b), "synthetic-token")
	require.NotContains(t, string(b), "selection_token")
}
func TestClaudeResetPastCooldownIsCleared(t *testing.T) {
	now := time.Now()
	past := now.Add(-time.Minute)
	no := false
	g := claudeResetGrant{ID: "grant", ResetsLeft: 1, UsableNow: true, UseRequiresLimit: &no, Clears: []string{"five_hour"}}
	r := projectClaudeResetCredits(&claudeResetBlock{Eligible: true, NextGrantID: g.ID, CooldownUntil: &past, Grants: []claudeResetGrant{g}}, now)
	require.Nil(t, r.CooldownUntil)
	require.Equal(t, 1, r.AvailableCount)
	future := now.Add(time.Hour)
	r = projectClaudeResetCredits(&claudeResetBlock{Eligible: true, NextGrantID: g.ID, CooldownUntil: &future, Grants: []claudeResetGrant{g}}, now)
	require.Equal(t, &future, r.CooldownUntil)
}
func TestClaudeResetEligibilityFailClosed(t *testing.T) {
	now := time.Now()
	past := now.Add(-time.Minute)
	future := now.Add(time.Hour)
	no := false
	base := claudeResetGrant{ID: "grant", ResetsLeft: 1, UsableNow: true, UseRequiresLimit: &no, Clears: []string{"five_hour"}}
	for _, name := range []string{"paused", "expired", "future", "cooldown", "requires-limit", "blocking", "ineligible", "spent", "not-next"} {
		t.Run(name, func(t *testing.T) {
			g := base
			b := &claudeResetBlock{Eligible: true, NextGrantID: g.ID}
			switch name {
			case "paused":
				g.Paused = true
			case "expired":
				g.EndsAt = &past
			case "future":
				g.StartsAt = &future
			case "cooldown":
				b.CooldownUntil = &future
			case "requires-limit":
				g.UseRequiresLimit = nil
			case "blocking":
				g.Blocking = []string{"seven_day"}
			case "ineligible":
				b.Eligible = false
			case "spent":
				g.ResetsLeft = 0
			case "not-next":
				b.NextGrantID = "other"
			}
			b.Grants = []claudeResetGrant{g}
			r := projectClaudeResetCredits(b, now)
			require.Zero(t, r.AvailableCount)
		})
	}
}
func TestClaudeResetStatusRejectsMissingScopeBeforeNetwork(t *testing.T) {
	s := &ClaudeResetCreditService{accounts: resetAccountStub{&Account{Platform: PlatformAnthropic, Type: AccountTypeOAuth}}, do: func(*http.Request, string) (*http.Response, error) { t.Fatal("network called"); return nil, nil }}
	_, e := s.Query(context.Background(), 1)
	require.Error(t, e)
}
func TestClaudeResetMalformedAndAbsent(t *testing.T) {
	for _, body := range []string{`{}`, `{"five_hour":{},"cedar_ember":null}`, `{"cedar_ember":{"eligible":true}}`, `{"error":{"message":"private upstream data"}}`, `not json`} {
		t.Run(body, func(t *testing.T) {
			s := &ClaudeResetCreditService{accounts: resetAccountStub{&Account{Platform: PlatformAnthropic, Type: AccountTypeOAuth, Credentials: map[string]any{"scope": "user:profile"}}}, tokens: resetTokenStub{}, now: time.Now, do: func(*http.Request, string) (*http.Response, error) {
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
			}}
			r, e := s.Query(context.Background(), 1)
			if body == `{}` || strings.Contains(body, `"cedar_ember":null`) {
				require.NoError(t, e)
				require.Empty(t, r.Credits)
			} else {
				require.Error(t, e)
				require.NotContains(t, e.Error(), "private upstream data")
			}
		})
	}
}
