---
layout: post
title: "Building Comprehensive DBT Documentation"
date: 2025-10-14
img: dbt.png
tags: [DBT, Documentation, Data Engineering]
---

## Table of Contents
- [The Challenge](#the-challenge)
- [The Solution](#the-solution)
- [Key Documentation Sections](#key-documentation-sections)
  - [Medallion Architecture](#medallion-architecture)
  - [Local Development Setup](#local-development-setup)
  - [DBT Commands Explained](#dbt-commands-explained)
  - [Testing Strategy](#testing-strategy)
- [Critical Lessons Learned](#critical-lessons-learned)
- [Documentation Structure](#documentation-structure)

## The Challenge

When working as the sole data engineer maintaining a DBT project with multiple dashboards and dozens of models, I realized I needed comprehensive documentation that would allow:
- Team members to work independently when I'm unavailable
- New engineers to onboard quickly
- Clear guidelines to prevent common mistakes

The existing documentation was scattered across README files and tribal knowledge. I needed a single source of truth.

## The Solution

I created a layered documentation system with:
1. **Quick Reference Summary** - Get answers in 30 seconds
2. **Detailed Guides** - Deep dives into specific topics
3. **Troubleshooting Playbooks** - Step-by-step recovery procedures

The documentation focuses on the **why** behind decisions, not just the **how**.

## Key Documentation Sections

### Medallion Architecture

We use the Bronze → Silver → Gold pattern, but I documented a critical decision point that isn't obvious:

**`SELECT *` vs Explicit Column Selection in Bronze Layer**

| Approach | Advantages | Disadvantages |
|----------|-----------|---------------|
| **`SELECT *`** | ✅ Fast to write<br>✅ Automatically gets new columns | ❌ Blocks app team from dropping unused columns<br>❌ Less control over ingested data |
| **Explicit Columns** | ✅ Doesn't block app column deletions<br>✅ Clear documentation of used fields | ❌ Must manually add new columns<br>❌ Slower initial development |

**The Trade-off**: We started with `SELECT *` for speed, but plan to migrate to explicit columns once models stabilize. This prevents us from blocking the application team when they need to drop deprecated columns.

### Local Development Setup

Most teams only document Docker-based workflows. I added a local development path that's 3x faster for iteration:

**Docker (Production-like):**
```bash
colima start
make all
```

**Local (Fast Development):**
```bash
# One-time setup
pip install dbt-postgres==1.9.0
dbt deps

# Run models
dbt run --target local
dbt run --target local --select +silver_marketplace_report  # With dependencies
dbt run --target local --select silver_marketplace_report+  # With dependents
```

**Key Innovation**: The `+` syntax for dependency selection wasn't obvious:
- `+model_name` - Run model AND everything it depends on
- `model_name+` - Run model AND everything that depends on it
- `+model_name+` - Run model with both upstream and downstream

### DBT Commands Explained

Many engineers know `dbt run`, but other commands are underutilized:

| Command | What It Does | When to Use |
|---------|-------------|-------------|
| `dbt run` | Executes models (builds tables/views) | Run transformations |
| `dbt compile` | Compiles to SQL **without** executing | Debug SQL before running |
| `dbt test` | Runs data quality tests | Validate data |
| `dbt build` | Runs models **AND** tests together | Full pipeline in one command |
| `dbt debug` | Tests connection and config | Troubleshoot connection issues |
| `dbt list` | Shows what would run (dry-run) | Preview impact before running |

The `dbt compile` + `cat target/compiled/...` workflow is invaluable for debugging complex Jinja logic.

### Testing Strategy

This section addresses a critical production issue we faced:

**The Problem**: Tests can pass in PR checks (empty test database) but fail after merge when hitting real data, causing everything to get stuck.

**The Recovery Process**:
1. Comment out the failing test in `schema.yml`
2. Investigate in SQL Lab with diagnostic queries
3. Fix the model SQL
4. Test in SQL Lab first (verify uniqueness/constraints)
5. Uncomment the test once validated

**Manual Testing Queries (Run BEFORE Adding Tests)**:

```sql
-- Check for duplicate rows
SELECT
    column1,
    column2,
    COUNT(*) AS duplicate_count
FROM transform.silver_my_table
GROUP BY column1, column2
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC;

-- Check for NULL values
SELECT
    COUNT(*) AS total_rows,
    COUNT(column_name) AS non_null_rows,
    COUNT(*) - COUNT(column_name) AS null_count
FROM transform.silver_my_table;
```

**Key Insight**: Always test models in SQL Lab with real data before adding DBT tests. Don't rely on empty test databases.

## Critical Lessons Learned

### 1. Referencing Data

| What | Syntax | Use Case |
|------|--------|----------|
| DBT Model | `{{ ref('model_name') }}` | Reference other bronze/silver/gold models (creates dependency graph) |
| Source Table | `{{ source('schema', 'table') }}` | Reference raw database tables (defined in `sources.yml`) |

Never use direct table names - always use `ref()` or `source()` to maintain the dependency graph.

### 2. Macros Are Advanced

Macros use advanced Jinja syntax and should be approached carefully:

```sql
-- Calling a macro is different from referencing models
{{ macro_name(argument1, argument2) }}

-- Example: Using dbt_utils surrogate_key
{{ dbt_utils.surrogate_key(['column1', 'column2']) }}
```

Document where to find examples (`macros/` directory) rather than trying to explain all Jinja features.

### 3. SQL Style Matters

Standardizing on **4-space indentation** and **ALL CAPS keywords** makes code reviews faster and reduces cognitive load:

```sql
SELECT
    column1,
    column2,
    CASE
        WHEN condition THEN value
        ELSE other_value
    END AS calculated_column
FROM {{ ref('bronze_table') }}
WHERE status = 'Active'
```

### 4. Infrastructure Documentation

Don't forget to document where things live:

**DBT Repository**: `dbt-project`
- All models, tests, macros, documentation
- Deployed via CI/CD

**Infrastructure Configuration**: `projects` repository
- Helm charts for deployments
- Configuration values
- Test in staging first, then promote to production

## Documentation Structure

The final structure provides multiple entry points:

```
docs/analytics-stack-guide/
├── README.md                          # Quick reference summary
├── 01-overview.md                     # Architecture & data flow
├── 02-dbt-setup.md                    # Installation & commands
├── 03-integration.md                  # Dashboard integration
├── 04-common-tasks.md                 # Step-by-step workflows
├── 05-troubleshooting.md              # Problem → Solution guide
├── 06-reference.md                    # Command cheat sheet
└── caching-slides.md                  # Visual presentations
```

This could be found in the repo [superset-dbt-workflow](https://github.com/kraftaa/superset-dbt-workflow), which I'm polishing and will make it public soon.

**Auto-generated documentation**:

This will create auto-generated documentation with the lineage, exposures and all models information

```
dbt docs generate
```

This one will serve it locally on `localhost:8080`
```
dbt docs serve
```

I have our docs hosted on S3 static page at, and I also included our specific instructions mentioned in `analytics-stack-guide` as a sub-topic.


4. **Maintained** - Links to auto-generated docs at `https://data.domain.io/`


This is not the perfect documentation - but I found it's to be useful, I'm keep adding new tricks and ideas.

---

*Full documentation available in the `docs/analytics-stack-guide/` directory of the sparkle-dbt repository.*
