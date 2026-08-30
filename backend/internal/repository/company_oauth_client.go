package repository

import (
	"github.com/Wei-Shaw/sub2api/internal/pkg/xai"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

// ProvideCompanyGrokOAuthClient deliberately ignores runtime endpoint
// overrides. Company V1 sends Grok OAuth secrets only to the audited official
// token endpoint.
func ProvideCompanyGrokOAuthClient() service.GrokOAuthClient {
	return &grokOAuthClient{tokenURL: xai.DefaultTokenURL}
}
