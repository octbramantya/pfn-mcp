-- Migration: Create meter_aggregations table
-- Purpose: Store named formula-based aggregations for correct facility consumption calculation
-- Related: pfn_mcp-i02.1

-- ============================================================================
-- SCHEMA
-- ============================================================================

CREATE TABLE IF NOT EXISTS meter_aggregations (
    id SERIAL PRIMARY KEY,
    tenant_id INTEGER NOT NULL REFERENCES tenants(id),
    name VARCHAR(100) NOT NULL,           -- e.g., "facility", "yarn_division"
    aggregation_type VARCHAR(50) NOT NULL, -- 'facility', 'department', 'sub_panel', 'custom'
    formula TEXT NOT NULL,                 -- e.g., "(94+11+27)-(84)"
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP DEFAULT NOW(),
    updated_at TIMESTAMP DEFAULT NOW(),

    UNIQUE(tenant_id, name)
);

COMMENT ON TABLE meter_aggregations IS 'Named formula-based aggregations for WAGES telemetry';
COMMENT ON COLUMN meter_aggregations.name IS 'Unique name within tenant (e.g., facility, yarn_division)';
COMMENT ON COLUMN meter_aggregations.aggregation_type IS 'Category: facility, department, sub_panel, custom';
COMMENT ON COLUMN meter_aggregations.formula IS 'Device ID formula: 94+11+27, 94-84, (94+11+27)-(84)';

CREATE INDEX IF NOT EXISTS idx_meter_aggregations_tenant ON meter_aggregations(tenant_id);
CREATE INDEX IF NOT EXISTS idx_meter_aggregations_type ON meter_aggregations(aggregation_type);

-- ============================================================================
-- INITIAL DATA
-- ============================================================================

-- PRS aggregations (tenant_id = 3)
-- Device hierarchy:
--   94 = Main incoming meter (Facility - Yarn)
--   84 = Fabric division meter
--   11 = Genset meter
--   27 = Solar PV meter

INSERT INTO meter_aggregations (tenant_id, name, aggregation_type, formula, description)
VALUES
    (3, 'facility', 'facility', '94+11+27', 'Total facility consumption: Main + Genset + Solar'),
    (3, 'fabric_division', 'department', '84+11+27', 'Fabric division: Fabric meter + Genset + Solar'),
    (3, 'yarn_division', 'department', '94-84', 'Yarn division = Facility main - Fabric (derived)')
ON CONFLICT (tenant_id, name) DO UPDATE SET
    formula = EXCLUDED.formula,
    description = EXCLUDED.description,
    updated_at = NOW();

-- IOP aggregations (tenant_id = 4)
-- Device hierarchy:
--   108 = LVMDP-1 (main incoming meter)
--   134, 109, 110 = Indosena department meters

INSERT INTO meter_aggregations (tenant_id, name, aggregation_type, formula, description)
VALUES
    (4, 'facility', 'facility', '108', 'Total facility: LVMDP-1 main meter'),
    (4, 'indosena', 'department', '134+109+110', 'Indosena department: sum of 3 meters')
ON CONFLICT (tenant_id, name) DO UPDATE SET
    formula = EXCLUDED.formula,
    description = EXCLUDED.description,
    updated_at = NOW();

-- ============================================================================
-- PERMISSIONS
-- ============================================================================

-- Grant read access to pfn_mcp_reader (used by MCP server)
GRANT SELECT ON meter_aggregations TO pfn_mcp_reader;
GRANT USAGE ON SEQUENCE meter_aggregations_id_seq TO pfn_mcp_reader;

-- ============================================================================
-- VERIFICATION QUERY (run after migration)
-- ============================================================================
-- SELECT t.tenant_name, ma.name, ma.aggregation_type, ma.formula, ma.description
-- FROM meter_aggregations ma
-- JOIN tenants t ON t.id = ma.tenant_id
-- WHERE ma.is_active = true
-- ORDER BY t.tenant_name, ma.name;
