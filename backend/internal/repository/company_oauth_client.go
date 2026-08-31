package repository

import (
	"fmt"
	"strings"

	"github.com/Wei-Shaw/sub2api/internal/pkg/xai"
	"github.com/Wei-Shaw/sub2api/internal/service"
	"github.com/imroc/req/v3"
)

// ProvideCompanyGrokOAuthClient deliberately ignores runtime endpoint
// overrides. Company V1 sends Grok OAuth secrets only to the audited official
// token endpoint.
func ProvideCompanyGrokOAuthClient() service.GrokOAuthClient {
	return &grokOAuthClient{tokenURL: xai.DefaultTokenURL}
}

// CreateCompanyPrivacyReqClient is the single production guard for OpenAI
// privacy calls. Existing Admin and refresh code may fail to hydrate a Proxy;
// an empty value must stop here instead of silently creating a direct client.
func CreateCompanyPrivacyReqClient(proxyURL string) (*req.Client, error) {
	if strings.TrimSpace(proxyURL) == "" {
		return nil, fmt.Errorf("company egress: privacy proxy URL is required")
	}
	return CreatePrivacyReqClient(proxyURL)
}
