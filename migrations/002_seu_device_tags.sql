-- Migration: Add SEU (Significant Energy User) device tags
-- These tags enable automatic SEU reporting in /daily-digest and /weekly-summary
--
-- INSTRUCTIONS:
-- 1. Replace XX, YY with actual device IDs for PRS compressors
-- 2. Replace AA, BB with actual device IDs for IOP press machines
-- 3. Run this migration against the database
--
-- To find device IDs:
--   SELECT id, display_name FROM devices WHERE tenant_id = 3 AND display_name ILIKE '%compressor%';
--   SELECT id, display_name FROM devices WHERE tenant_id = 4 AND display_name ILIKE '%press%';

-- PRS: Compressors (tenant_id = 3)
-- Significant energy users - compressed air system
INSERT INTO device_tags (device_id, tag_key, tag_value, tag_category, tag_description, is_active)
VALUES
    (XX, 'seu_type', 'compressor', 'energy_management', 'Compressor - Significant Energy User', true),
    (YY, 'seu_type', 'compressor', 'energy_management', 'Compressor - Significant Energy User', true)
ON CONFLICT DO NOTHING;

-- IOP: Press machines (tenant_id = 4)
-- Significant energy users - press/stamping equipment
INSERT INTO device_tags (device_id, tag_key, tag_value, tag_category, tag_description, is_active)
VALUES
    (AA, 'seu_type', 'press_machine', 'energy_management', 'Press Machine - Significant Energy User', true),
    (BB, 'seu_type', 'press_machine', 'energy_management', 'Press Machine - Significant Energy User', true)
ON CONFLICT DO NOTHING;

-- Verification query (run after migration):
-- SELECT d.display_name, dt.tag_value, t.tenant_name
-- FROM device_tags dt
-- JOIN devices d ON d.id = dt.device_id
-- JOIN tenants t ON t.id = d.tenant_id
-- WHERE dt.tag_key = 'seu_type' AND dt.is_active = true;
