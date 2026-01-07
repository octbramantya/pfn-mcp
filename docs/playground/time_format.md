Show me `MC-3`average L-L for the last 5 minutes

get_device_telemetryRequest{
  `period`: `5m`,
  `device_name`: `MC-3`,
  `quantity_search`: `voltage L-L avg`
}
ResponseError: Device not found: MC-3Thought processThe device wasn't found with that name. Let me try to resolve the device first to see what the actual name is.

Let me search for that device:2 stepsPlist_devicesRequest{
  `search`: `MC`,
  `tenant`: `PRS`
}ResponseFound 20 device(s):


## Primarajuli Sukses

- **MC 1** (ID: 37)
  Type: Power Meter | Code: `MC1`
- **MC 10** (ID: 45)
  Type: Power Meter | Code: `MC10`
- **MC 11** (ID: 46)
  Type: Power Meter | Code: `MC11`
- **MC 12** (ID: 56)
  Type: Power Meter | Code: `MC12`
- **MC 2** (ID: 38)
  Type: Power Meter | Code: `MC2`
- **MC 3** (ID: 103)
  Type: Power Meter | Code: `MC3`
- **MC 4** (ID: 40)
  Type: Power Meter | Code: `MC4`
- **MC 7** (ID: 43)
  Type: Power Meter | Code: `MC7`
- **MC 8** (ID: 44)
  Type: Power Meter | Code: `MC8`
- **MC 9** (ID: 55)
  Type: Power Meter | Code: `MC9`
- **MC ATY** (ID: 101)
  Type: Power Meter | Code: `MCATY`
- **MC Line I** (ID: 81)
  Type: Power Meter | Code: `MC-I`
- **MC Line J** (ID: 82)
  Type: Power Meter | Code: `MC-J`
- **MC SP Line D** (ID: 79)
  Type: Power Meter | Code: `MC-D`
- **MC SP Line E** (ID: 76)
  Type: Power Meter | Code: `MC-E`
- **MC SP Line F** (ID: 77)
  Type: Power Meter | Code: `MC-F`
- **MC SP Line G** (ID: 78)
  Type: Power Meter | Code: `MC-G`
- **MC SP Line H** (ID: 80)
  Type: Power Meter | Code: `MC-H`
- **MC Tricot 1** (ID: 35)
  Type: Power Meter | Code: `SPN`
- **MC Tricot 2** (ID: 36)
  Type: Power Meter | Code: `SPM-2`Thought processFound it - the device is named "MC 3" (with a space) not "MC-3". The device ID is 103. Now let me query the telemetry for voltage L-L average.Found it - the device is named MC 3 (with a space). Let me get the voltage data:Pget_device_telemetryRequest{
  `period`: `5m`,
  `device_id`: 103,
  `quantity_search`: `voltage L-L avg`
}Response## Telemetry: MC 3
**Quantity**: 100ms Voltage A-B (-)
**Period**: 2025-08-10T03:45:28 to 2026-01-07T03:45:28
**Bucket**: 1week (16 points)

### Summary
- **Average**: 405.54 
- **Min**: 398.45 
- **Max**: 411.77 

### Data Points
- 2025-09-22T00:00:00: avg=404.590, min=401.354, max=408.022
- 2025-09-29T00:00:00: avg=405.297, min=400.720, max=410.402
- 2025-10-06T00:00:00: avg=406.012, min=401.404, max=410.523
  ... (10 more points) ...
- 2025-12-22T00:00:00: avg=403.747, min=398.452, max=409.457
- 2025-12-29T00:00:00: avg=405.681, min=400.388, max=411.114
- 2026-01-05T00:00:00: avg=407.111, min=401.219, max=411.536Thought processThe system is returning weekly aggregated data because it auto-selected a bucket size. For just 5 minutes of data, I need to use a smaller bucket. Let me try with explicit start/end dates or a smaller bucket size like 15min. Actually, let me check what the minimum bucket size is - it seems to be 15min. For 5 minutes of data, I should use explicit dates and maybe look at the most recent raw data available.
Actually, looking at this response, it seems the data returned is historical, not real-time. The system is showing data from 2025-09-22 onwards. Let me try to get more recent data with a smaller bucket.The system auto-aggregated to weekly buckets. Let me get the most recent data with finer granularity:Pget_device_telemetryRequest{
  `bucket`: `15min`,
  `period`: `1h`,
  `device_id`: 103,
  `quantity_search`: `voltage L-L avg`
}Response## Telemetry: MC 3
**Quantity**: 100ms Voltage A-B (-)
**Period**: 2026-01-07T02:45:40 to 2026-01-07T03:45:40
**Bucket**: 15min (2 points)

### Summary
- **Average**: 409.21 
- **Min**: 408.73 
- **Max**: 409.70 

### Data Points
- 2026-01-07T03:00:00: avg=409.700, min=409.700, max=409.700
- 2026-01-07T03:15:00: avg=408.727, min=408.727, max=408.727Thought processNow we have recent data, but only 2 data points in the last hour. This suggests the device may not have high-frequency data available. For the last 5 minutes, I can summarize what we have. The most recent reading is from 03:15:00 at 408.73V.
The system's minimum bucket is 15min, so for a 5-minute window, we'll only see 1 data point if any. Let me present what we have.

# Comments
1. For presentation to user, better to use UTC+7 (assumed user local time), or if we can, infer the timezone from local settings.
2. Based on the thought process, it seems that the tool is using `telemetry_15min_agg`. Has the Smart time range selection (auto-select `telemetry_data` vs `telemetry_15min_agg`) has been developed in the tools (see `../concept.md` on Phase 2 features)

