package repository

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/pkg/proxyurl"
	"github.com/Wei-Shaw/sub2api/internal/pkg/proxyutil"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

const (
	companyProbeAURL      = "https://api.ipify.org?format=json"
	companyProbeBURL      = "https://cloudflare.com/cdn-cgi/trace"
	companyProbeTimeout   = 10 * time.Second
	companyProbeBodyLimit = int64(16 * 1024)
	companyProbeUserAgent = "sub2api-company-egress-health/1"
)

type managedProxyHealthKey struct {
	proxyID     int64
	fingerprint string
}

type managedProxyHealthState struct {
	status    string
	exitIPv4  string
	checkedAt time.Time
	epoch     uint64
	message   string
}

func managedProxyHealthReady(status string) bool {
	return status == service.ManagedProxyHealthReadyPrimary || status == service.ManagedProxyHealthReadyDisaster
}

type companyManagedProxyHealth struct {
	mu           sync.Mutex
	states       map[managedProxyHealthKey]managedProxyHealthState
	fingerprints map[int64]string
	policies     *service.ManagedProxyPolicies
	proxies      service.ProxyRepository
	now          func() time.Time
}

// NewCompanyManagedProxyHealth performs the startup preflight. No managed
// request can be served unless every configured Proxy has fresh, matching
// exit-IP and country evidence.
func NewCompanyManagedProxyHealth(
	policies *service.ManagedProxyPolicies,
	proxies service.ProxyRepository,
) (service.ManagedProxyHealthGate, error) {
	if policies == nil || proxies == nil {
		return nil, fmt.Errorf("%w: health dependency is nil", service.ErrManagedEgressPolicy)
	}
	health := &companyManagedProxyHealth{
		states:       make(map[managedProxyHealthKey]managedProxyHealthState),
		fingerprints: make(map[int64]string),
		policies:     policies,
		proxies:      proxies,
		now:          time.Now,
	}
	if policies.DevelopmentBypass() {
		return health, nil
	}
	for _, policy := range policies.Entries() {
		proxy, err := proxies.GetByID(context.Background(), policy.ProxyID)
		if err != nil {
			return nil, fmt.Errorf("company egress startup preflight proxy %d: %w", policy.ProxyID, err)
		}
		if err := service.ValidateManagedProxy(policy, proxy); err != nil {
			return nil, err
		}
		fingerprint := service.ManagedProxyFingerprint(policy, proxy)
		health.fingerprints[policy.ProxyID] = fingerprint
		ctx, cancel := context.WithTimeout(context.Background(), 2*companyProbeTimeout)
		_, err = health.probeAndStore(ctx, policy, proxy, fingerprint)
		cancel()
		if err != nil {
			return nil, fmt.Errorf("company egress startup preflight proxy %d: %w", policy.ProxyID, err)
		}
	}
	go health.runPeriodicProbes()
	return health, nil
}

func (h *companyManagedProxyHealth) runPeriodicProbes() {
	ticker := time.NewTicker(service.ManagedProxyHealthProbeInterval)
	defer ticker.Stop()
	for range ticker.C {
		for _, policy := range h.policies.Entries() {
			fingerprint := h.fingerprints[policy.ProxyID]
			key := managedProxyHealthKey{proxyID: policy.ProxyID, fingerprint: fingerprint}
			proxy, err := h.proxies.GetByID(context.Background(), policy.ProxyID)
			if err != nil {
				h.storeFailure(key, "proxy lookup failed")
				continue
			}
			if err := service.ValidateManagedProxy(policy, proxy); err != nil {
				h.storeFailure(key, "proxy invariant changed")
				continue
			}
			if service.ManagedProxyFingerprint(policy, proxy) != fingerprint {
				h.storeFailure(key, "proxy fingerprint changed")
				continue
			}
			ctx, cancel := context.WithTimeout(context.Background(), 2*companyProbeTimeout)
			_, _ = h.probeAndStore(ctx, policy, proxy, fingerprint)
			cancel()
		}
	}
}

func (h *companyManagedProxyHealth) RequireReady(
	ctx context.Context,
	policy service.ManagedProxyPolicy,
	proxy *service.Proxy,
	fingerprint string,
) (service.ManagedProxyHealthResult, error) {
	if h.policies.DevelopmentBypass() {
		return service.ManagedProxyHealthResult{
			Epoch:    1,
			State:    service.ManagedProxyHealthReadyPrimary,
			ExitIPv4: policy.ExpectedExitIPv4,
		}, nil
	}
	if err := service.ValidateManagedProxy(policy, proxy); err != nil {
		return service.ManagedProxyHealthResult{}, err
	}
	if fingerprint == "" || fingerprint != service.ManagedProxyFingerprint(policy, proxy) {
		return service.ManagedProxyHealthResult{}, fmt.Errorf("policy fingerprint mismatch")
	}
	if expected := h.fingerprints[policy.ProxyID]; expected == "" || fingerprint != expected {
		return service.ManagedProxyHealthResult{}, fmt.Errorf("startup proxy fingerprint mismatch")
	}

	key := managedProxyHealthKey{proxyID: policy.ProxyID, fingerprint: fingerprint}
	h.mu.Lock()
	state, ok := h.states[key]
	now := h.now()
	if ok && managedProxyHealthReady(state.status) && now.Sub(state.checkedAt) >= service.ManagedProxyHealthTTL {
		h.mu.Unlock()
		return service.ManagedProxyHealthResult{}, fmt.Errorf("health evidence expired")
	}
	if ok && managedProxyHealthReady(state.status) && now.Sub(state.checkedAt) < service.ManagedProxyHealthProbeInterval {
		h.mu.Unlock()
		return service.ManagedProxyHealthResult{Epoch: state.epoch, State: state.status, ExitIPv4: state.exitIPv4}, nil
	}
	if ok && !managedProxyHealthReady(state.status) && now.Sub(state.checkedAt) < service.ManagedProxyHealthProbeInterval {
		h.mu.Unlock()
		return service.ManagedProxyHealthResult{}, fmt.Errorf("route unhealthy: %s", state.message)
	}
	h.mu.Unlock()

	current, err := h.proxies.GetByID(ctx, policy.ProxyID)
	if err != nil {
		h.storeFailure(key, "proxy lookup failed")
		return service.ManagedProxyHealthResult{}, fmt.Errorf("proxy lookup failed: %w", err)
	}
	if err := service.ValidateManagedProxy(policy, current); err != nil {
		h.storeFailure(key, "proxy invariant changed")
		return service.ManagedProxyHealthResult{}, err
	}
	if service.ManagedProxyFingerprint(policy, current) != fingerprint {
		h.storeFailure(key, "proxy fingerprint changed")
		return service.ManagedProxyHealthResult{}, fmt.Errorf("proxy fingerprint changed")
	}
	return h.probeAndStore(ctx, policy, current, fingerprint)
}

func (h *companyManagedProxyHealth) probeAndStore(
	ctx context.Context,
	policy service.ManagedProxyPolicy,
	proxy *service.Proxy,
	fingerprint string,
) (service.ManagedProxyHealthResult, error) {
	key := managedProxyHealthKey{proxyID: policy.ProxyID, fingerprint: fingerprint}
	evidence, err := probeCompanyManagedExit(ctx, proxy.URL())
	if err != nil {
		h.storeFailure(key, err.Error())
		return service.ManagedProxyHealthResult{}, err
	}
	status, err := validateCompanyExitEvidence(policy, evidence)
	if err != nil {
		h.storeFailure(key, err.Error())
		return service.ManagedProxyHealthResult{}, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	previous := h.states[key]
	epoch := previous.epoch + 1
	h.states[key] = managedProxyHealthState{
		status:    status,
		exitIPv4: evidence.ipA,
		checkedAt: h.now(),
		epoch:     epoch,
	}
	return service.ManagedProxyHealthResult{Epoch: epoch, State: status, ExitIPv4: evidence.ipA}, nil
}

func validateCompanyExitEvidence(policy service.ManagedProxyPolicy, evidence companyExitEvidence) (string, error) {
	if evidence.ipA != evidence.ipB {
		return service.ManagedProxyHealthUnhealthy, fmt.Errorf("probe IP disagreement")
	}
	if evidence.countryCode != policy.CountryCode {
		return service.ManagedProxyHealthUnhealthy, fmt.Errorf("exit country mismatch")
	}
	switch evidence.ipA {
	case policy.ExpectedExitIPv4:
		return service.ManagedProxyHealthReadyPrimary, nil
	case policy.DisasterExitIPv4:
		if policy.DisasterExitIPv4 != "" {
			return service.ManagedProxyHealthReadyDisaster, nil
		}
	}
	return service.ManagedProxyHealthUnhealthy, fmt.Errorf("exit IPv4 mismatch")
}

func (h *companyManagedProxyHealth) storeFailure(key managedProxyHealthKey, message string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	previous := h.states[key]
	h.states[key] = managedProxyHealthState{
		status:    service.ManagedProxyHealthUnhealthy,
		checkedAt: h.now(),
		epoch:     previous.epoch + 1,
		message:   message,
	}
}

type companyExitEvidence struct {
	ipA         string
	ipB         string
	countryCode string
}

func probeCompanyManagedExit(ctx context.Context, rawProxyURL string) (companyExitEvidence, error) {
	_, parsedProxy, err := proxyurl.Parse(rawProxyURL)
	if err != nil || parsedProxy == nil {
		return companyExitEvidence{}, fmt.Errorf("invalid managed proxy URL")
	}
	transport, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return companyExitEvidence{}, fmt.Errorf("default HTTP transport type is unsupported")
	}
	cloned := transport.Clone()
	cloned.Proxy = nil
	cloned.TLSClientConfig = nil
	cloned.ForceAttemptHTTP2 = true
	if err := proxyutil.ConfigureTransportProxy(cloned, parsedProxy); err != nil {
		return companyExitEvidence{}, fmt.Errorf("configure managed proxy: %w", err)
	}
	defer cloned.CloseIdleConnections()
	client := &http.Client{
		Transport: cloned,
		Timeout:   companyProbeTimeout,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	bodyA, err := companyProbeGET(ctx, client, companyProbeAURL)
	if err != nil {
		return companyExitEvidence{}, fmt.Errorf("probe A: %w", err)
	}
	var ipify struct {
		IP string `json:"ip"`
	}
	if err := json.Unmarshal(bodyA, &ipify); err != nil {
		return companyExitEvidence{}, fmt.Errorf("probe A parse failure")
	}
	ipA, err := service.CanonicalPublicIPv4(ipify.IP)
	if err != nil {
		return companyExitEvidence{}, fmt.Errorf("probe A: %w", err)
	}

	bodyB, err := companyProbeGET(ctx, client, companyProbeBURL)
	if err != nil {
		return companyExitEvidence{}, fmt.Errorf("probe B: %w", err)
	}
	var ipB, country string
	for _, line := range strings.Split(string(bodyB), "\n") {
		key, value, found := strings.Cut(strings.TrimSpace(line), "=")
		if !found {
			continue
		}
		switch key {
		case "ip":
			ipB = strings.TrimSpace(value)
		case "loc":
			country = strings.ToUpper(strings.TrimSpace(value))
		}
	}
	ipB, err = service.CanonicalPublicIPv4(ipB)
	if err != nil {
		return companyExitEvidence{}, fmt.Errorf("probe B: %w", err)
	}
	if len(country) != 2 {
		return companyExitEvidence{}, fmt.Errorf("probe B country is missing or invalid")
	}
	return companyExitEvidence{ipA: ipA, ipB: ipB, countryCode: country}, nil
}

func companyProbeGET(ctx context.Context, client *http.Client, exactURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, exactURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", companyProbeUserAgent)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected HTTP status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, companyProbeBodyLimit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > companyProbeBodyLimit {
		return nil, fmt.Errorf("response body exceeds limit")
	}
	return body, nil
}
