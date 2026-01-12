'use client';

import { useState } from 'react';

import { Button } from '@/components/ui/button';
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu';
import { useAuth } from '@/contexts/AuthContext';
import { switchTenant } from '@/lib/api';

export function TenantSelector() {
  const { user, setEffectiveTenant } = useAuth();
  const [isLoading, setIsLoading] = useState(false);

  // Only show for superusers
  if (!user?.is_superuser) {
    return null;
  }

  // Get tenant options from user groups (excluding 'superuser')
  const tenantOptions = user.groups.filter((g) => g !== 'superuser' && g !== '/superuser');

  const handleSelectTenant = async (tenantCode: string | null) => {
    setIsLoading(true);
    try {
      await switchTenant(tenantCode);
      setEffectiveTenant(tenantCode);
    } catch (error) {
      console.error('Failed to switch tenant:', error);
    } finally {
      setIsLoading(false);
    }
  };

  const currentTenant = user.effective_tenant || 'All Tenants';

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="outline" size="sm" disabled={isLoading}>
          {isLoading ? 'Switching...' : currentTenant}
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuLabel>Select Tenant</DropdownMenuLabel>
        <DropdownMenuSeparator />
        <DropdownMenuItem
          onClick={() => handleSelectTenant(null)}
          className={!user.effective_tenant ? 'bg-accent' : ''}
        >
          All Tenants
        </DropdownMenuItem>
        {tenantOptions.map((tenant) => {
          const code = tenant.replace(/^\//, ''); // Remove leading slash
          return (
            <DropdownMenuItem
              key={code}
              onClick={() => handleSelectTenant(code)}
              className={user.effective_tenant === code ? 'bg-accent' : ''}
            >
              {code}
            </DropdownMenuItem>
          );
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
