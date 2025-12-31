"""
Copyright (c) 2024, Oracle and/or its affiliates.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

     https://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
"""

import pytest

from dbt.tests.util import run_dbt


# Model that will be materialized as external table
EXTERNAL_TABLE_MODEL = """
{{ config(
    materialized='external_table',
    directory_name='DBT_EXT_DIR',
    directory_path='/tmp/dbt_external',
    csv_file_name='test_external.csv'
) }}

SELECT 1 as id, 'Alice' as name FROM DUAL
UNION ALL
SELECT 2 as id, 'Bob' as name FROM DUAL
UNION ALL
SELECT 3 as id, 'Charlie' as name FROM DUAL
"""

# Model using external table with custom delimiter
EXTERNAL_TABLE_CUSTOM_DELIMITER = """
{{ config(
    materialized='external_table',
    directory_name='DBT_EXT_DIR',
    directory_path='/tmp/dbt_external',
    csv_file_name='test_pipe_delimited.csv',
    field_delimiter='|'
) }}

SELECT 100 as product_id, 'Widget' as product_name, 19.99 as price FROM DUAL
UNION ALL
SELECT 200 as product_id, 'Gadget' as product_name, 29.99 as price FROM DUAL
"""

# Seed file for testing
SEED_CSV = """id,name,value
1,test1,100
2,test2,200
3,test3,300
"""

# Model that references a seed
EXTERNAL_TABLE_FROM_SEED = """
{{ config(
    materialized='external_table',
    directory_name='DBT_EXT_DIR',
    directory_path='/tmp/dbt_external',
    csv_file_name='from_seed.csv'
) }}

SELECT id, name, value FROM {{ ref('my_seed') }}
"""


class TestExternalTableBasic:
    """Test basic external table materialization functionality."""

    @pytest.fixture(scope="class")
    def models(self):
        return {
            "my_external_table.sql": EXTERNAL_TABLE_MODEL,
        }

    def test_external_table_creation(self, project):
        """Test that an external table can be created from a simple query."""
        results = run_dbt(["run"])
        assert len(results) == 1
        # Verify the external table was created
        result = project.run_sql(
            "SELECT COUNT(*) FROM my_external_table",
            fetch="one"
        )
        assert result[0] == 3


class TestExternalTableCustomDelimiter:
    """Test external table with custom field delimiter."""

    @pytest.fixture(scope="class")
    def models(self):
        return {
            "custom_delimiter.sql": EXTERNAL_TABLE_CUSTOM_DELIMITER,
        }

    def test_custom_delimiter(self, project):
        """Test that external table works with custom field delimiter."""
        results = run_dbt(["run"])
        assert len(results) == 1
        # Verify the data
        result = project.run_sql(
            "SELECT COUNT(*) FROM custom_delimiter",
            fetch="one"
        )
        assert result[0] == 2


class TestExternalTableFromSeed:
    """Test external table materialization from seed data."""

    @pytest.fixture(scope="class")
    def seeds(self):
        return {
            "my_seed.csv": SEED_CSV,
        }

    @pytest.fixture(scope="class")
    def models(self):
        return {
            "ext_from_seed.sql": EXTERNAL_TABLE_FROM_SEED,
        }

    def test_external_table_from_seed(self, project):
        """Test that an external table can be created from seed data."""
        # First run seeds
        run_dbt(["seed"])
        # Then run the model
        results = run_dbt(["run"])
        assert len(results) == 1
        # Verify the data
        result = project.run_sql(
            "SELECT COUNT(*) FROM ext_from_seed",
            fetch="one"
        )
        assert result[0] == 3


class TestExternalTableFullRefresh:
    """Test external table full refresh behavior."""

    @pytest.fixture(scope="class")
    def models(self):
        return {
            "refreshable_ext.sql": EXTERNAL_TABLE_MODEL.replace(
                "test_external.csv", "refreshable.csv"
            ).replace("my_external_table", "refreshable_ext"),
        }

    def test_full_refresh(self, project):
        """Test that external table can be fully refreshed."""
        # Initial run
        run_dbt(["run"])
        # Full refresh
        results = run_dbt(["run", "--full-refresh"])
        assert len(results) == 1
        # Verify data still accessible
        result = project.run_sql(
            "SELECT COUNT(*) FROM refreshable_ext",
            fetch="one"
        )
        assert result[0] == 3
