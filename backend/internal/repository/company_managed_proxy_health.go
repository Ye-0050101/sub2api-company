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
	ready     bool
	checkedAt time.Time
	epoch     uint64
	message   string
}

type companyManagedProxyHealth struct {
	mu       sync.Mutex
	states   map[managedProxyHealthKey]managedProxyHealthState
	fingerprints map[int64]string
	policies *service.ManagedProxyPolicies
	proxies  service.ProxyRepository
	now      func() time.Time
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
) (uint64, error) {
	if h.policies.DevelopmentBypass() {
		return 1, nil
	}
	if err := service.ValidateManagedProxy(policy, proxy); err != nil {
		return 0, err
	}
	if fingerprint == "" || fingerprint != service.ManagedProxyFingerprint(policy, proxy) {
		return 0, fmt.Errorf("policy fingerprint mismatch")
	}
	if expected := h.fingerprints[policy.ProxyID]; expected == "" || fingerprint != expected {
		return 0, fmt.Errorf("startup proxy fingerprint mismatch")
	}

	key := managedProxyHealthKey{proxyID: policy.ProxyID, fingerprint: fingerprint}
	h.mu.Lock()
	state, ok := h.states[key]
	now := h.now()
	if ok && state.ready && now.Sub(state.checkedAt) >= service.ManagedProxyHealthTTL {
		h.mu.Unlock()
		return 0, fmt.Errorf("health evidence expired")
	}
	if ok && state.ready && now.Sub(state.checkedAt) < service.ManagedProxyHealthProbeInterval {
		h.mu.Unlock()
		return state.epoch, nil
	}
	if ok && !state.ready && now.Sub(state.checkedAt) < service.ManagedProxyHealthProbeInterval {
		h.mu.Unlock()
		return 0, fmt.Errorf("route unhealthy: %s", state.message)
	}
	h.mu.Unlock()

	current, err := h.proxies.GetByID(ctx, policy.ProxyID)
	if err != nil {
		h.storeFailure(key, "proxy lookup failed")
		return 0, fmt.Errorf("proxy lookup failed: %w", err)
	}
	if err := service.ValidateManagedProxy(policy, current); err != nil {
		h.storeFailure(key, "proxy invariant changed")
		return 0, err
	}
	if service.ManagedProxyFingerprint(policy, current) != fingerprint {
		h.storeFailure(key, "proxy fingerprint changed")
		return 0, fmt.Errorf("proxy fingerprint changed")
	}
	return h.probeAndStore(ctx, policy, current, fingerprint)
}

func (h *companyManagedProxyHealth) probeAndStore(
	ctx context.Context,
	policy service.ManagedProxyPolicy,
	proxy *service.Proxy,
	fingerprint string,
) (uint64, error) {
	key := managedProxyHealthKey{proxyID: policy.ProxyID, fingerprint: fingerprint}
	evidence, err := probeCompanyManagedExit(ctx, proxy.URL())
	if err != nil {
		h.storeFailure(key, err.Error())
		return 0, err
	}
	err = validateCompanyExitEvidence(policy, evidence)
	if err != nil {
		h.storeFailure(key, err.Error())
		return 0, err
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	previous := h.states[key]
	epoch := previous.epoch + 1
	h.states[key] = managedProxyHealthState{ready: true, checkedAt: h.now(), epoch: epoch}
	return epoch, nil
}

func validateCompanyExitEvidence(policy service.ManagedProxyPolicy, evidence companyExitEvidence) error {
	if evidence.ipA != evidence.ipB {
		return fmt.Errorf("probe IP disagreement")
	}
	if evidence.ipA != policy.ExpectedExitIPv4 {
		return fmt.Errorf("exit IPv4 mismatch")
	}
	if evidence.countryCode != policy.CountryCode {
		return fmt.Errorf("exit country mismatch")
	}
	return nil
}

func (h *companyManagedProxyHealth) storeFailure(key managedProxyHealthKey, message string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	previous := h.states[key]
	h.states[key] = managedProxyHealthState{
		ready:     false,
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
