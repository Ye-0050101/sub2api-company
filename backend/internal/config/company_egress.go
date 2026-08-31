package config

// CompanyEgressConfig keys deterministic account egress policy by the
// existing Proxy ID, so the company fork needs no route table or migration.
type CompanyEgressConfig struct {
	DevelopmentBypass bool                        `mapstructure:"development_bypass"`
	ManagedProxies    []CompanyManagedProxyConfig `mapstructure:"managed_proxies"`
}

type CompanyManagedProxyConfig struct {
	ProxyID          int64  `mapstructure:"proxy_id"`
	Class            string `mapstructure:"class"`
	CountryCode      string `mapstructure:"country_code"`
	ExpectedExitIPv4 string `mapstructure:"expected_exit_ipv4"`
}
