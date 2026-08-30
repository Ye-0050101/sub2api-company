package repository

import (
	"fmt"
	"net/http"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/pkg/tlsfingerprint"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

// RawHTTPUpstream is intentionally a distinct DI type. Account-sensitive
// services receive service.HTTPUpstream (the company decorator), never this
// unguarded implementation.
type RawHTTPUpstream struct {
	upstream service.HTTPUpstream
}

func ProvideRawHTTPUpstream(cfg *config.Config) RawHTTPUpstream {
	return RawHTTPUpstream{upstream: NewHTTPUpstream(cfg)}
}

type companyHTTPUpstream struct {
	raw      service.HTTPUpstream
	resolver service.ManagedProxyResolver
}

func NewCompanyHTTPUpstream(
	raw RawHTTPUpstream,
	resolver service.ManagedProxyResolver,
) (service.HTTPUpstream, error) {
	if raw.upstream == nil || resolver == nil {
		return nil, fmt.Errorf("%w: HTTP upstream dependency is nil", service.ErrManagedEgressPolicy)
	}
	return &companyHTTPUpstream{raw: raw.upstream, resolver: resolver}, nil
}

func (s *companyHTTPUpstream) ManagedProxyResolver() service.ManagedProxyResolver {
	if s == nil {
		return nil
	}
	return s.resolver
}

func (s *companyHTTPUpstream) Do(
	req *http.Request,
	callerProxyURL string,
	accountID int64,
	accountConcurrency int,
) (*http.Response, error) {
	if s.resolver.DevelopmentBypass() {
		return s.raw.Do(req, callerProxyURL, accountID, accountConcurrency)
	}
	decision, guardedReq, err := s.resolveRequest(req, accountID)
	if err != nil {
		return nil, err
	}
	return s.raw.Do(guardedReq, decision.ProxyURL, accountID, accountConcurrency)
}

func (s *companyHTTPUpstream) DoWithTLS(
	req *http.Request,
	callerProxyURL string,
	accountID int64,
	accountConcurrency int,
	profile *tlsfingerprint.Profile,
) (*http.Response, error) {
	if s.resolver.DevelopmentBypass() {
		return s.raw.DoWithTLS(req, callerProxyURL, accountID, accountConcurrency, profile)
	}
	decision, guardedReq, err := s.resolveRequest(req, accountID)
	if err != nil {
		return nil, err
	}
	return s.raw.DoWithTLS(guardedReq, decision.ProxyURL, accountID, accountConcurrency, profile)
}

func (s *companyHTTPUpstream) resolveRequest(
	req *http.Request,
	accountID int64,
) (service.ManagedProxyDecision, *http.Request, error) {
	if req == nil || req.URL == nil {
		return service.ManagedProxyDecision{}, nil, fmt.Errorf("%w: nil HTTP request", service.ErrManagedEgressPolicy)
	}
	decision, err := s.resolver.ResolveForAccount(req.Context(), accountID)
	if err != nil {
		return service.ManagedProxyDecision{}, nil, err
	}
	if err := service.ValidateManagedDestination(decision, req.URL, false); err != nil {
		return service.ManagedProxyDecision{}, nil, err
	}
	// Provider APIs in the supported V1 matrix do not require cross-host
	// redirects. Disabling them prevents an approved hostname from becoming an
	// open redirect to an unapproved destination inside the raw client's loop.
	ctx := service.WithHTTPUpstreamRedirectsDisabled(req.Context())
	return decision, req.Clone(ctx), nil
}
