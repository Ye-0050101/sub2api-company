package service

import (
	"context"
	"fmt"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/config"
)

func companyAccountProxyURL(account *Account) string {
	if account == nil || account.ProxyID == nil || account.Proxy == nil {
		return ""
	}
	return account.Proxy.URL()
}

func resolveCompanyWebSocketProxy(
	ctx context.Context,
	cfg *config.Config,
	resolver ManagedProxyResolver,
	account *Account,
	wsURL string,
) (string, error) {
	callerProxyURL := companyAccountProxyURL(account)
	if resolver == nil {
		if cfg != nil && strings.EqualFold(strings.TrimSpace(cfg.Server.Mode), "release") {
			return "", fmt.Errorf("%w: websocket resolver is missing in release mode", ErrManagedEgressPolicy)
		}
		return callerProxyURL, nil
	}
	decision, err := ResolveManagedProxyForURL(ctx, resolver, account, wsURL, callerProxyURL, true)
	if err != nil {
		return "", err
	}
	if !resolver.DevelopmentBypass() && decision.ProxyURL == "" {
		return "", fmt.Errorf("%w: websocket proxy URL is empty", ErrManagedEgressPolicy)
	}
	return decision.ProxyURL, nil
}
