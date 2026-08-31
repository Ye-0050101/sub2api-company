package repository

import (
	"context"
	"database/sql"

	dbent "github.com/Wei-Shaw/sub2api/ent"
	infraerrors "github.com/Wei-Shaw/sub2api/internal/pkg/errors"
	"github.com/Wei-Shaw/sub2api/internal/service"
)

var ErrCompanyManagedProxyReadOnly = infraerrors.Conflict("MANAGED_PROXY_READ_ONLY", "company managed proxy is read-only")

// RawProxyRepository is a distinct DI type so normal production consumers
// cannot bypass the managed-Proxy read-only guard.
type RawProxyRepository struct {
	service.ProxyRepository
}

func ProvideRawProxyRepository(client *dbent.Client, sqlDB *sql.DB) RawProxyRepository {
	return RawProxyRepository{ProxyRepository: NewProxyRepository(client, sqlDB)}
}

type companyProxyRepository struct {
	service.ProxyRepository
	policies *service.ManagedProxyPolicies
}

func NewCompanyProxyRepository(
	raw RawProxyRepository,
	policies *service.ManagedProxyPolicies,
) service.ProxyRepository {
	return &companyProxyRepository{ProxyRepository: raw.ProxyRepository, policies: policies}
}

func (r *companyProxyRepository) Update(ctx context.Context, proxy *service.Proxy) error {
	if proxy != nil && r.policies != nil && r.policies.IsManagedProxy(proxy.ID) {
		return ErrCompanyManagedProxyReadOnly
	}
	return r.ProxyRepository.Update(ctx, proxy)
}

func (r *companyProxyRepository) Delete(ctx context.Context, id int64) error {
	if r.policies != nil && r.policies.IsManagedProxy(id) {
		return ErrCompanyManagedProxyReadOnly
	}
	return r.ProxyRepository.Delete(ctx, id)
}
