/**
 * SWR configuration and utilities
 * Provides request deduplication, caching, and revalidation
 */

import useSWR, { SWRConfiguration } from 'swr';
import useSWRImmutable from 'swr/immutable';

import { fetchAPI } from './api';

/**
 * Default SWR fetcher using our authenticated API client
 */
export async function swrFetcher<T>(url: string): Promise<T> {
  return fetchAPI<T>(url);
}

/**
 * Default SWR configuration
 */
export const swrConfig: SWRConfiguration = {
  fetcher: swrFetcher,
  revalidateOnFocus: false,
  revalidateOnReconnect: true,
  dedupingInterval: 2000,
  errorRetryCount: 3,
};

/**
 * Hook for mutable data that should be revalidated
 */
export function useAPI<T>(
  key: string | null,
  config?: SWRConfiguration<T>
) {
  return useSWR<T>(key, swrFetcher, {
    ...swrConfig,
    ...config,
  });
}

/**
 * Hook for immutable data that won't change
 */
export function useImmutableAPI<T>(
  key: string | null,
  config?: SWRConfiguration<T>
) {
  return useSWRImmutable<T>(key, swrFetcher, {
    ...swrConfig,
    ...config,
  });
}
