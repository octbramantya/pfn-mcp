'use client';

import { useEffect, useState } from 'react';

import { Progress } from '@/components/ui/progress';
import { getUsage } from '@/lib/api';
import type { UsageStats } from '@/lib/types';

export function UsageMeter() {
  const [usage, setUsage] = useState<UsageStats | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    const loadUsage = async () => {
      try {
        const data = await getUsage('monthly');
        setUsage(data);
      } catch (error) {
        console.error('Failed to load usage:', error);
      } finally {
        setIsLoading(false);
      }
    };

    loadUsage();

    // Refresh every 5 minutes
    const interval = setInterval(loadUsage, 5 * 60 * 1000);
    return () => clearInterval(interval);
  }, []);

  if (isLoading || !usage) {
    return null;
  }

  // Don't show if no budget is configured
  if (usage.budget_used_percent === null) {
    return null;
  }

  const percent = Math.min(100, Math.round(usage.budget_used_percent));
  const isWarning = usage.is_near_limit;
  const isOver = usage.is_over_budget;

  return (
    <div className="space-y-1">
      <div className="flex justify-between text-xs">
        <span className="text-muted-foreground">Budget</span>
        <span
          className={
            isOver
              ? 'text-destructive font-medium'
              : isWarning
                ? 'text-yellow-600'
                : 'text-muted-foreground'
          }
        >
          {percent}%
        </span>
      </div>
      <Progress
        value={percent}
        className={`h-1.5 ${
          isOver
            ? '[&>div]:bg-destructive'
            : isWarning
              ? '[&>div]:bg-yellow-500'
              : ''
        }`}
      />
      {isOver && (
        <p className="text-xs text-destructive">Budget exceeded</p>
      )}
    </div>
  );
}
