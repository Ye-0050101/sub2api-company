package service

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"regexp"
	"testing"

	"github.com/Wei-Shaw/sub2api/internal/pkg/openai"
	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/require"
)

var companyCodexStableVersionPattern = regexp.MustCompile(`^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$`)

// TestCompanyCodexCandidateOfflineContract is deliberately offline. It proves
// that the exact candidate recorded by company-update.ps1 is accepted by the
// current source tree and reaches the production /v1/responses request builder
// as one self-consistent User-Agent / originator / version identity. It does
// not claim that a real OpenAI account or future upstream behavior is compatible.
func TestCompanyCodexCandidateOfflineContract(t *testing.T) {
	candidate := os.Getenv("COMPANY_CODEX_CANDIDATE_VERSION")
	if candidate == "" {
		t.Skip("COMPANY_CODEX_CANDIDATE_VERSION is supplied by Company CI")
	}
	require.Regexp(t, companyCodexStableVersionPattern, candidate)
	require.Equal(t, candidate, NormalizeCodexClientVersion(candidate))

	SetCodexCanonicalUserAgentResolver(func() string {
		return openai.CodexDefaultOriginator + "/" + candidate + codexCLIUserAgentSuffix
	})
	t.Cleanup(func() { SetCodexCanonicalUserAgentResolver(nil) })
	SetCodexIdentityEnforcementEnabled(true)
	t.Cleanup(func() { SetCodexIdentityEnforcementEnabled(true) })

	body := []byte(`{"model":"gpt-6-astra","input":"candidate contract check","stream":true}`)
	recorder := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(recorder)
	c.Request = httptest.NewRequest(http.MethodPost, "/v1/responses", bytes.NewReader(body))

	account := &Account{
		ID:       1,
		Platform: PlatformOpenAI,
		Type:     AccountTypeOAuth,
		Credentials: map[string]any{
			"chatgpt_account_id": "offline-contract-account",
		},
	}
	service := &OpenAIGatewayService{}
	request, err := service.buildUpstreamRequest(
		context.Background(), c, account, body, "offline-placeholder-token", true, "", true,
	)
	require.NoError(t, err)
	require.Equal(t, chatgptCodexURL, request.URL.String())
	require.Equal(t, http.MethodPost, request.Method)
	require.Equal(t, "application/json", request.Header.Get("Content-Type"))
	require.Equal(t, openai.CodexDefaultOriginator, request.Header.Get("Originator"))
	require.Equal(t, candidate, request.Header.Get("Version"))
	require.Equal(t, openai.CodexDefaultOriginator+"/"+candidate+codexCLIUserAgentSuffix, request.Header.Get("User-Agent"))

	wireBody, err := io.ReadAll(request.Body)
	require.NoError(t, err)
	var decoded map[string]any
	require.NoError(t, json.Unmarshal(wireBody, &decoded))
	require.Equal(t, "gpt-6-astra", decoded["model"])
	require.Equal(t, "candidate contract check", decoded["input"])
	require.Equal(t, true, decoded["stream"])
}
