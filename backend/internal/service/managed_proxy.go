package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/pkg/proxyurl"
)

const (
	ManagedProxyClassInternational = "INTERNATIONAL_PROXY"
	ManagedProxyClassCNDirect      = "CN_DIRECT"
	managedProxyStartupTimeout     = 10 * time.Second
)

var (
	ErrManagedEgressUnsupported = errors.New("company egress: account type is unsupported")
	ErrManagedEgressNotReady    = errors.New("company egress: proxy health is not ready")
	ErrManagedEgressPolicy      = errors.New("company egress: policy violation")
)

// ManagedProxyPolicy is immutable after startup and is keyed by the existing
// Proxy ID. Environment-specific IDs and exit addresses stay out of the DB
// schema and out of ordinary admin CRUD.
type ManagedProxyPolicy struct {
	ProxyID          int64
	Class            string
	CountryCode      string
	ExpectedExitIPv4 string
}

type ManagedProxyPolicies struct {
	entries           map[int64]ManagedProxyPolicy
	developmentBypass bool
}

func NewManagedProxyPolicies(cfg *config.Config) (*ManagedProxyPolicies, error) {
	if cfg == nil {
		return nil, fmt.Errorf("%w: nil config", ErrManagedEgressPolicy)
	}
	if cfg.CompanyEgress.DevelopmentBypass {
		if strings.EqualFold(strings.TrimSpace(cfg.Server.Mode), "release") {
			return nil, fmt.Errorf("%w: development bypass is forbidden in release mode", ErrManagedEgressPolicy)
		}
		return &ManagedProxyPolicies{entries: map[int64]ManagedProxyPolicy{}, developmentBypass: true}, nil
	}
	if cfg.Gateway.Grok.PasswordAuthEnabled {
		return nil, fmt.Errorf("%w: Grok password/captcha authorization is unsupported", ErrManagedEgressPolicy)
	}
	if cfg.BatchImage.Enabled || cfg.BatchImage.QueueEnabled || cfg.BatchImage.VertexEnabled {
		return nil, fmt.Errorf("%w: Gemini Batch and Vertex Batch/GCS are unsupported", ErrManagedEgressPolicy)
	}
	if cfg.Security.ProxyFallback.AllowDirectOnError {
		return nil, fmt.Errorf("%w: direct fallback must be disabled", ErrManagedEgressPolicy)
	}
	if len(cfg.CompanyEgress.ManagedProxies) == 0 {
		return nil, fmt.Errorf("%w: managed_proxies must not be empty", ErrManagedEgressPolicy)
	}

	policies := &ManagedProxyPolicies{entries: make(map[int64]ManagedProxyPolicy, len(cfg.CompanyEgress.ManagedProxies))}
	for index, raw := range cfg.CompanyEgress.ManagedProxies {
		policy, err := normalizeManagedProxyPolicy(raw)
		if err != nil {
			return nil, fmt.Errorf("company_egress.managed_proxies[%d]: %w", index, err)
		}
		if _, exists := policies.entries[policy.ProxyID]; exists {
			return nil, fmt.Errorf("%w: duplicate proxy_id %d", ErrManagedEgressPolicy, policy.ProxyID)
		}
		policies.entries[policy.ProxyID] = policy
	}
	return policies, nil
}

func resolveConfiguredManagedProxyID(
	ctx context.Context,
	resolver ManagedProxyResolver,
	proxyID *int64,
	platform string,
	accountType string,
) (ManagedProxyDecision, error) {
	if resolver == nil || resolver.DevelopmentBypass() {
		return ManagedProxyDecision{}, fmt.Errorf("%w: managed resolver is not enforcing", ErrManagedEgressPolicy)
	}
	if proxyID == nil || *proxyID <= 0 {
		return ManagedProxyDecision{}, fmt.Errorf("%w: proxy_id is required", ErrManagedEgressPolicy)
	}
	return resolver.ResolveForProxyID(ctx, *proxyID, platform, accountType)
}

func resolveConfiguredManagedAccount(
	ctx context.Context,
	resolver ManagedProxyResolver,
	account *Account,
) (ManagedProxyDecision, error) {
	if resolver == nil || resolver.DevelopmentBypass() {
		return ManagedProxyDecision{}, fmt.Errorf("%w: managed resolver is not enforcing", ErrManagedEgressPolicy)
	}
	if account == nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: account is nil", ErrManagedEgressPolicy)
	}
	return resolver.ResolveForAccount(ctx, account.ID)
}

func managedOAuthSessionProxyID(sessionProxyID int64, supplied *int64) (*int64, error) {
	if sessionProxyID <= 0 {
		return nil, fmt.Errorf("%w: OAuth session has no proxy_id", ErrManagedEgressPolicy)
	}
	if supplied != nil && *supplied != sessionProxyID {
		return nil, fmt.Errorf("%w: OAuth callback proxy_id does not match the session", ErrManagedEgressPolicy)
	}
	value := sessionProxyID
	return &value, nil
}

func normalizeManagedProxyPolicy(raw config.CompanyManagedProxyConfig) (ManagedProxyPolicy, error) {
	policy := ManagedProxyPolicy{
		ProxyID:          raw.ProxyID,
		Class:            strings.ToUpper(strings.TrimSpace(raw.Class)),
		CountryCode:      strings.ToUpper(strings.TrimSpace(raw.CountryCode)),
		ExpectedExitIPv4: strings.TrimSpace(raw.ExpectedExitIPv4),
	}
	if policy.ProxyID <= 0 {
		return ManagedProxyPolicy{}, fmt.Errorf("%w: proxy_id must be positive", ErrManagedEgressPolicy)
	}
	switch policy.Class {
	case ManagedProxyClassInternational:
		if policy.CountryCode != "US" && policy.CountryCode != "SG" {
			return ManagedProxyPolicy{}, fmt.Errorf("%w: international country must be US or SG", ErrManagedEgressPolicy)
		}
	case ManagedProxyClassCNDirect:
		if policy.CountryCode != "CN" {
			return ManagedProxyPolicy{}, fmt.Errorf("%w: CN_DIRECT country must be CN", ErrManagedEgressPolicy)
		}
	default:
		return ManagedProxyPolicy{}, fmt.Errorf("%w: unsupported class %q", ErrManagedEgressPolicy, policy.Class)
	}
	canonicalIP, err := CanonicalPublicIPv4(policy.ExpectedExitIPv4)
	if err != nil {
		return ManagedProxyPolicy{}, fmt.Errorf("%w: expected_exit_ipv4 must be a canonical public IPv4", ErrManagedEgressPolicy)
	}
	policy.ExpectedExitIPv4 = canonicalIP
	return policy, nil
}

var managedNonPublicIPv4Prefixes = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("127.0.0.0/8"),
	netip.MustParsePrefix("169.254.0.0/16"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("192.88.99.0/24"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("224.0.0.0/4"),
	netip.MustParsePrefix("240.0.0.0/4"),
}

func CanonicalPublicIPv4(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	addr, err := netip.ParseAddr(trimmed)
	if err != nil || !addr.Is4() || addr.String() != trimmed || !addr.IsGlobalUnicast() {
		return "", fmt.Errorf("not a canonical public IPv4")
	}
	for _, prefix := range managedNonPublicIPv4Prefixes {
		if prefix.Contains(addr) {
			return "", fmt.Errorf("not a public IPv4")
		}
	}
	return addr.String(), nil
}

func (p *ManagedProxyPolicies) DevelopmentBypass() bool {
	return p != nil && p.developmentBypass
}

func (p *ManagedProxyPolicies) Lookup(proxyID int64) (ManagedProxyPolicy, bool) {
	if p == nil {
		return ManagedProxyPolicy{}, false
	}
	policy, ok := p.entries[proxyID]
	return policy, ok
}

func (p *ManagedProxyPolicies) Entries() []ManagedProxyPolicy {
	if p == nil {
		return nil
	}
	out := make([]ManagedProxyPolicy, 0, len(p.entries))
	for _, policy := range p.entries {
		out = append(out, policy)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ProxyID < out[j].ProxyID })
	return out
}

func (p *ManagedProxyPolicies) IsManagedProxy(proxyID int64) bool {
	_, ok := p.Lookup(proxyID)
	return ok
}

type ManagedProxyDecision struct {
	AccountID          int64
	EffectiveAccountID int64
	Platform           string
	AccountType        string
	ProxyID            int64
	ProxyURL           string
	ProxyClass         string
	CountryCode        string
	ExpectedExitIPv4   string
	PolicyFingerprint  string
	HealthEpoch        uint64
}

type ManagedProxyHealthGate interface {
	RequireReady(ctx context.Context, policy ManagedProxyPolicy, proxy *Proxy, fingerprint string) (uint64, error)
}

type ManagedProxyResolver interface {
	ResolveForAccount(ctx context.Context, accountID int64) (ManagedProxyDecision, error)
	ResolveForProxyID(ctx context.Context, proxyID int64, platform, accountType string) (ManagedProxyDecision, error)
	DevelopmentBypass() bool
}

type ManagedProxyResolverProvider interface {
	ManagedProxyResolver() ManagedProxyResolver
}

func ResolveManagedProxyForURL(
	ctx context.Context,
	resolver ManagedProxyResolver,
	account *Account,
	targetURL string,
	callerProxyURL string,
	allowWebSocket bool,
) (ManagedProxyDecision, error) {
	if resolver == nil || account == nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: managed resolver or account is nil", ErrManagedEgressPolicy)
	}
	if resolver.DevelopmentBypass() {
		return ManagedProxyDecision{
			AccountID:          account.ID,
			EffectiveAccountID: account.ID,
			Platform:           account.Platform,
			AccountType:        account.Type,
			ProxyURL:           strings.TrimSpace(callerProxyURL),
		}, nil
	}
	decision, err := resolver.ResolveForAccount(ctx, account.ID)
	if err != nil {
		return ManagedProxyDecision{}, err
	}
	target, err := url.Parse(strings.TrimSpace(targetURL))
	if err != nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: destination URL is invalid", ErrManagedEgressPolicy)
	}
	if err := ValidateManagedDestination(decision, target, allowWebSocket); err != nil {
		return ManagedProxyDecision{}, err
	}
	return decision, nil
}

type managedProxyResolver struct {
	accounts AccountRepository
	proxies  ProxyRepository
	policies *ManagedProxyPolicies
	health   ManagedProxyHealthGate
}

func NewManagedProxyResolver(
	accounts AccountRepository,
	proxies ProxyRepository,
	policies *ManagedProxyPolicies,
	health ManagedProxyHealthGate,
) (ManagedProxyResolver, error) {
	if accounts == nil || proxies == nil || policies == nil || health == nil {
		return nil, fmt.Errorf("%w: resolver dependency is nil", ErrManagedEgressPolicy)
	}
	resolver := &managedProxyResolver{accounts: accounts, proxies: proxies, policies: policies, health: health}
	if policies.DevelopmentBypass() {
		return resolver, nil
	}

	seenEndpoints := make(map[string]int64, len(policies.entries))
	for _, policy := range policies.Entries() {
		lookupCtx, cancel := context.WithTimeout(context.Background(), managedProxyStartupTimeout)
		proxy, err := proxies.GetByID(lookupCtx, policy.ProxyID)
		cancel()
		if err != nil {
			return nil, fmt.Errorf("%w: load managed proxy %d: %v", ErrManagedEgressPolicy, policy.ProxyID, err)
		}
		if err := ValidateManagedProxy(policy, proxy); err != nil {
			return nil, err
		}
		endpoint := proxy.Protocol + "://" + proxy.Host + ":" + strconv.Itoa(proxy.Port)
		if existingID, exists := seenEndpoints[endpoint]; exists {
			return nil, fmt.Errorf("%w: managed proxies %d and %d share endpoint %s", ErrManagedEgressPolicy, existingID, proxy.ID, endpoint)
		}
		seenEndpoints[endpoint] = proxy.ID
	}
	return resolver, nil
}

func (r *managedProxyResolver) DevelopmentBypass() bool {
	return r != nil && r.policies.DevelopmentBypass()
}

func (r *managedProxyResolver) ResolveForAccount(ctx context.Context, accountID int64) (ManagedProxyDecision, error) {
	if accountID <= 0 {
		return ManagedProxyDecision{}, fmt.Errorf("%w: account id is required", ErrManagedEgressPolicy)
	}
	account, err := r.accounts.GetByID(ctx, accountID)
	if err != nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: load account %d: %v", ErrManagedEgressPolicy, accountID, err)
	}
	if account == nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: account %d not found", ErrManagedEgressPolicy, accountID)
	}
	effective, err := resolveCredentialAccount(ctx, r.accounts, account)
	if err != nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: %v", ErrManagedEgressPolicy, err)
	}
	if effective == nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: effective account is nil", ErrManagedEgressPolicy)
	}
	if account.IsShadow() {
		if account.ProxyID == nil || effective.ProxyID == nil || *account.ProxyID != *effective.ProxyID {
			return ManagedProxyDecision{}, fmt.Errorf("%w: shadow and parent proxy IDs must match", ErrManagedEgressPolicy)
		}
	}
	return r.resolve(ctx, account.ID, effective)
}

func (r *managedProxyResolver) ResolveForProxyID(
	ctx context.Context,
	proxyID int64,
	platform string,
	accountType string,
) (ManagedProxyDecision, error) {
	account := &Account{Platform: platform, Type: accountType, ProxyID: &proxyID}
	return r.resolve(ctx, 0, account)
}

func (r *managedProxyResolver) resolve(ctx context.Context, requestedAccountID int64, account *Account) (ManagedProxyDecision, error) {
	requiredClass, err := managedClassForAccount(account)
	if err != nil {
		return ManagedProxyDecision{}, err
	}
	if managedCustomBaseURLConfigured(account) {
		return ManagedProxyDecision{}, fmt.Errorf("%w: managed custom_base_url is forbidden", ErrManagedEgressPolicy)
	}
	if account.ProxyID == nil || *account.ProxyID <= 0 {
		return ManagedProxyDecision{}, fmt.Errorf("%w: managed account requires proxy_id", ErrManagedEgressPolicy)
	}
	policy, ok := r.policies.Lookup(*account.ProxyID)
	if !ok {
		return ManagedProxyDecision{}, fmt.Errorf("%w: proxy_id %d has no immutable company policy", ErrManagedEgressPolicy, *account.ProxyID)
	}
	if policy.Class != requiredClass {
		return ManagedProxyDecision{}, fmt.Errorf("%w: account class %s cannot use proxy class %s", ErrManagedEgressPolicy, requiredClass, policy.Class)
	}
	proxy, err := r.proxies.GetByID(ctx, policy.ProxyID)
	if err != nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: load proxy %d: %v", ErrManagedEgressPolicy, policy.ProxyID, err)
	}
	if err := ValidateManagedProxy(policy, proxy); err != nil {
		return ManagedProxyDecision{}, err
	}
	proxyURL, parsed, err := proxyurl.Parse(proxy.URL())
	if err != nil || proxyURL == "" || parsed == nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: managed proxy URL is invalid", ErrManagedEgressPolicy)
	}
	fingerprint := ManagedProxyFingerprint(policy, proxy)
	epoch, err := r.health.RequireReady(ctx, policy, proxy, fingerprint)
	if err != nil {
		return ManagedProxyDecision{}, fmt.Errorf("%w: proxy %d: %v", ErrManagedEgressNotReady, policy.ProxyID, err)
	}
	return ManagedProxyDecision{
		AccountID:          requestedAccountID,
		EffectiveAccountID: account.ID,
		Platform:           account.Platform,
		AccountType:        account.Type,
		ProxyID:            policy.ProxyID,
		ProxyURL:           proxyURL,
		ProxyClass:         policy.Class,
		CountryCode:        policy.CountryCode,
		ExpectedExitIPv4:   policy.ExpectedExitIPv4,
		PolicyFingerprint:  fingerprint,
		HealthEpoch:        epoch,
	}, nil
}

func managedClassForAccount(account *Account) (string, error) {
	if account == nil {
		return "", fmt.Errorf("%w: nil account", ErrManagedEgressPolicy)
	}
	supported := false
	switch account.Platform {
	case PlatformAnthropic:
		supported = account.Type == AccountTypeOAuth || account.Type == AccountTypeSetupToken || account.Type == AccountTypeAPIKey
	case PlatformOpenAI:
		supported = account.Type == AccountTypeOAuth || account.Type == AccountTypeSetupToken || account.Type == AccountTypeAPIKey
	case PlatformGrok:
		supported = account.Type == AccountTypeOAuth || account.Type == AccountTypeAPIKey
	case PlatformGemini:
		supported = account.Type == AccountTypeOAuth || account.Type == AccountTypeAPIKey
	case PlatformKimi, PlatformZhipu, PlatformDeepseek:
		if account.Type == AccountTypeAPIKey {
			return ManagedProxyClassCNDirect, nil
		}
		return "", fmt.Errorf("%w: %s/%s", ErrManagedEgressUnsupported, account.Platform, account.Type)
	default:
		return "", fmt.Errorf("%w: %s/%s", ErrManagedEgressUnsupported, account.Platform, account.Type)
	}
	if !supported {
		return "", fmt.Errorf("%w: %s/%s", ErrManagedEgressUnsupported, account.Platform, account.Type)
	}
	return ManagedProxyClassInternational, nil
}

func managedCustomBaseURLConfigured(account *Account) bool {
	if account == nil {
		return false
	}
	if account.IsCustomBaseURLEnabled() || strings.TrimSpace(account.GetCustomBaseURL()) != "" {
		return true
	}

	// Several upstream account formats persist their official endpoint in
	// credentials.base_url. Keep those canonical provider URLs compatible, but
	// reject relays, generic upstreams, Ollama Cloud, and malformed endpoints.
	baseURL := strings.TrimSpace(account.GetCredential("base_url"))
	if baseURL == "" {
		return false
	}
	parsed, err := url.Parse(baseURL)
	if err != nil {
		return true
	}
	decision := ManagedProxyDecision{Platform: account.Platform}
	return ValidateManagedDestination(decision, parsed, false) != nil
}

func ValidateManagedProxy(policy ManagedProxyPolicy, proxy *Proxy) error {
	if proxy == nil || proxy.ID != policy.ProxyID {
		return fmt.Errorf("%w: proxy identity mismatch", ErrManagedEgressPolicy)
	}
	if proxy.Protocol != "socks5h" {
		return fmt.Errorf("%w: proxy %d protocol must be socks5h", ErrManagedEgressPolicy, proxy.ID)
	}
	addr, err := netip.ParseAddr(proxy.Host)
	if err != nil || !addr.Is4() || !addr.IsLoopback() || addr.String() != proxy.Host {
		return fmt.Errorf("%w: proxy %d host must be a canonical literal IPv4 in 127.0.0.0/8", ErrManagedEgressPolicy, proxy.ID)
	}
	if proxy.Port < 1 || proxy.Port > 65535 {
		return fmt.Errorf("%w: proxy %d port is invalid", ErrManagedEgressPolicy, proxy.ID)
	}
	if proxy.Username != "" || proxy.Password != "" {
		return fmt.Errorf("%w: proxy %d credentials are forbidden", ErrManagedEgressPolicy, proxy.ID)
	}
	if proxy.Status != StatusActive {
		return fmt.Errorf("%w: proxy %d is not active", ErrManagedEgressPolicy, proxy.ID)
	}
	if proxy.ExpiresAt != nil {
		return fmt.Errorf("%w: proxy %d expires_at must be NULL", ErrManagedEgressPolicy, proxy.ID)
	}
	if proxy.FallbackMode != FallbackModeNone {
		return fmt.Errorf("%w: proxy %d fallback_mode must be none", ErrManagedEgressPolicy, proxy.ID)
	}
	if proxy.BackupProxyID != nil {
		return fmt.Errorf("%w: proxy %d backup_proxy_id must be NULL", ErrManagedEgressPolicy, proxy.ID)
	}
	return nil
}

func ManagedProxyFingerprint(policy ManagedProxyPolicy, proxy *Proxy) string {
	value := strings.Join([]string{
		"company-proxyid-v1",
		strconv.FormatInt(policy.ProxyID, 10),
		policy.Class,
		policy.CountryCode,
		policy.ExpectedExitIPv4,
		proxy.Protocol,
		proxy.Host,
		strconv.Itoa(proxy.Port),
		strconv.FormatBool(proxy.Username != ""),
		strconv.FormatBool(proxy.Password != ""),
		proxy.Status,
		strconv.FormatBool(proxy.ExpiresAt != nil),
		proxy.FallbackMode,
		strconv.FormatBool(proxy.BackupProxyID != nil),
	}, "\x00")
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

var managedDestinationHosts = map[string]map[string]struct{}{
	PlatformAnthropic: hostSet("api.anthropic.com", "claude.ai", "claude.com", "platform.claude.com"),
	PlatformOpenAI:    hostSet("api.openai.com", "auth.openai.com", "chatgpt.com"),
	PlatformGrok: hostSet(
		"api.x.ai", "auth.x.ai", "accounts.x.ai", "cli-chat-proxy.grok.com",
		"us-east-1.api.x.ai", "us-west-2.api.x.ai", "eu-west-1.api.x.ai",
	),
	PlatformGemini: hostSet(
		"generativelanguage.googleapis.com", "cloudcode-pa.googleapis.com",
		"accounts.google.com", "oauth2.googleapis.com",
		"cloudresourcemanager.googleapis.com", "www.googleapis.com",
	),
	PlatformDeepseek: hostSet("api.deepseek.com"),
	PlatformKimi:     hostSet("api.moonshot.cn", "api.kimi.com"),
	PlatformZhipu:    hostSet("open.bigmodel.cn", "api.z.ai"),
}

func hostSet(hosts ...string) map[string]struct{} {
	set := make(map[string]struct{}, len(hosts))
	for _, host := range hosts {
		set[host] = struct{}{}
	}
	return set
}

// ValidateManagedDestination applies the source-reviewed exact HTTPS/WSS host
// policy. There are no wildcard suffixes and no administrator-added hosts.
func ValidateManagedDestination(decision ManagedProxyDecision, target *url.URL, allowWebSocket bool) error {
	if target == nil || target.User != nil {
		return fmt.Errorf("%w: destination URL is invalid", ErrManagedEgressPolicy)
	}
	scheme := strings.ToLower(target.Scheme)
	if scheme != "https" && (!allowWebSocket || scheme != "wss") {
		return fmt.Errorf("%w: managed destination must use HTTPS", ErrManagedEgressPolicy)
	}
	if port := target.Port(); port != "" && port != "443" {
		return fmt.Errorf("%w: managed destination port must be 443", ErrManagedEgressPolicy)
	}
	host := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(target.Hostname()), "."))
	allowed, exists := managedDestinationHosts[decision.Platform]
	if !exists {
		return fmt.Errorf("%w: no destination policy for platform %s", ErrManagedEgressUnsupported, decision.Platform)
	}
	if _, ok := allowed[host]; !ok {
		return fmt.Errorf("%w: destination host is not approved for platform %s", ErrManagedEgressPolicy, decision.Platform)
	}
	return nil
}

const (
	ManagedProxyHealthProbeInterval = 60 * time.Second
	ManagedProxyHealthTTL           = 120 * time.Second
)
