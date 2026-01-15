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
        <Button
          variant="ghost"
          size="sm"
          disabled={isLoading}
          className="h-8 text-muted-foreground hover:text-foreground gap-1.5"
        >
          <span className="text-xs">{isLoading ? 'Switching...' : currentTenant}</span>
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className="h-3 w-3">
            <path d="m6 9 6 6 6-6"/>
          </svg>
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="min-w-[140px]">
        <DropdownMenuLabel className="text-xs text-muted-foreground font-normal">Switch Tenant</DropdownMenuLabel>
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
