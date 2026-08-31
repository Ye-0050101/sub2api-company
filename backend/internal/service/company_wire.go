package service

import (
	"github.com/Wei-Shaw/sub2api/internal/config"
	"github.com/Wei-Shaw/sub2api/internal/pkg/geminicli"
	"github.com/redis/go-redis/v9"
)

func ProvideCompanyGrokOAuthService(
	proxyRepo ProxyRepository,
	oauthClient GrokOAuthClient,
	cfg *config.Config,
	redisClient *redis.Client,
	resolver ManagedProxyResolver,
) *GrokOAuthService {
	svc := ProvideGrokOAuthService(proxyRepo, oauthClient, cfg, redisClient)
	svc.SetManagedProxyResolver(resolver)
	return svc
}

func ProvideCompanyOAuthService(
	proxyRepo ProxyRepository,
	oauthClient ClaudeOAuthClient,
	resolver ManagedProxyResolver,
) *OAuthService {
	svc := NewOAuthService(proxyRepo, oauthClient)
	svc.SetManagedProxyResolver(resolver)
	return svc
}

func ProvideCompanyOpenAIOAuthService(
	proxyRepo ProxyRepository,
	oauthClient OpenAIOAuthClient,
	privacyClientFactory PrivacyClientFactory,
	resolver ManagedProxyResolver,
) *OpenAIOAuthService {
	svc := ProvideOpenAIOAuthService(proxyRepo, oauthClient, privacyClientFactory)
	svc.SetManagedProxyResolver(resolver)
	return svc
}

func ProvideCompanyGeminiOAuthService(
	proxyRepo ProxyRepository,
	oauthClient GeminiOAuthClient,
	codeAssist GeminiCliCodeAssistClient,
	driveClient geminicli.DriveClient,
	cfg *config.Config,
	resolver ManagedProxyResolver,
) *GeminiOAuthService {
	svc := NewGeminiOAuthService(proxyRepo, oauthClient, codeAssist, driveClient, cfg)
	svc.SetManagedProxyResolver(resolver)
	return svc
}

func ProvideCompanyAntigravityOAuthService(
	proxyRepo ProxyRepository,
	resolver ManagedProxyResolver,
) *AntigravityOAuthService {
	svc := NewAntigravityOAuthService(proxyRepo)
	svc.SetManagedProxyResolver(resolver)
	return svc
}

func ProvideCompanyOpenAIQuotaService(
	accountRepo AccountRepository,
	proxyRepo ProxyRepository,
	tokenProvider *OpenAITokenProvider,
	privacyClientFactory PrivacyClientFactory,
	openAIGatewayService *OpenAIGatewayService,
) *OpenAIQuotaService {
	svc := ProvideOpenAIQuotaService(accountRepo, proxyRepo, tokenProvider, privacyClientFactory, openAIGatewayService)
	svc.SetManagedProxyResolver(openAIGatewayService.managedProxyResolver)
	return svc
}

func ProvideCompanyAccountUsageService(
	accountRepo AccountRepository,
	usageLogRepo UsageLogRepository,
	usageFetcher ClaudeUsageFetcher,
	geminiQuotaService *GeminiQuotaService,
	antigravityQuotaFetcher *AntigravityQuotaFetcher,
	grokQuotaFetcher *GrokQuotaFetcher,
	grokQuotaService *GrokQuotaService,
	openAIQuotaService *OpenAIQuotaService,
	cache *UsageCache,
	identityCache IdentityCache,
	tlsFPProfileService *TLSFingerprintProfileService,
	openAIGatewayService *OpenAIGatewayService,
	httpUpstream HTTPUpstream,
) *AccountUsageService {
	svc := ProvideAccountUsageService(
		accountRepo,
		usageLogRepo,
		usageFetcher,
		geminiQuotaService,
		antigravityQuotaFetcher,
		grokQuotaFetcher,
		grokQuotaService,
		openAIQuotaService,
		cache,
		identityCache,
		tlsFPProfileService,
		openAIGatewayService,
	)
	svc.SetHTTPUpstream(httpUpstream)
	return svc
}
