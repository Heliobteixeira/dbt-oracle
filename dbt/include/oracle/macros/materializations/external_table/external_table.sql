{#
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
#}

{#
  External Table Materialization for Oracle

  This materialization:
  1. Executes the model SQL to produce data
  2. Writes the data to a CSV file in the specified Oracle directory
  3. Creates an external table that reads from that CSV file

  Configuration options:
  - directory_name: Name of the Oracle directory object (required)
  - directory_path: Path for the Oracle directory (optional, needed if directory doesn't exist)
  - csv_file_name: Name of the CSV file (default: model_name.csv)
  - field_delimiter: CSV field delimiter (default: ',')
  - line_terminator: Line terminator (default: 'NEWLINE')
  - skip_headers: Number of header lines to skip (default: 1, since we write headers)
  - encoding: Character encoding (default: 'AL32UTF8')

  Example usage:
    {{ config(
        materialized='external_table',
        directory_name='MY_DATA_DIR',
        directory_path='/path/to/data',
        csv_file_name='my_data.csv'
    ) }}

    SELECT * FROM my_source_table
#}

{% materialization external_table, adapter='oracle' %}

  {%- set identifier = model['alias'] -%}
  {%- set grant_config = config.get('grants') -%}

  {# Configuration for external table #}
  {%- set directory_name = config.require('directory_name') -%}
  {%- set directory_path = config.get('directory_path', none) -%}
  {%- set csv_file_name = config.get('csv_file_name', identifier ~ '.csv') -%}
  {%- set field_delimiter = config.get('field_delimiter', ',') -%}
  {%- set line_terminator = config.get('line_terminator', 'NEWLINE') -%}
  {%- set skip_headers = config.get('skip_headers', 1) -%}
  {%- set encoding = config.get('encoding', 'AL32UTF8') -%}

  {%- set old_relation = adapter.get_relation(database=database, schema=schema, identifier=identifier) -%}
  {%- set target_relation = api.Relation.create(identifier=identifier,
                                                schema=schema,
                                                database=database,
                                                type='table') -%}

  {{ run_hooks(pre_hooks, inside_transaction=False) }}

  -- `BEGIN` happens here:
  {{ run_hooks(pre_hooks, inside_transaction=True) }}

  {# Drop old relation if exists #}
  {{ drop_relation_if_exists(old_relation) }}

  {# Step 1: Create directory if path is provided #}
  {% if directory_path %}
    {% call statement('create_directory') %}
      {{ oracle__create_directory_if_not_exists(directory_name, directory_path) }}
    {% endcall %}
  {% endif %}

  {# Step 2: Get the columns from the query #}
  {% call statement('get_columns', fetch_result=True) %}
    {{ oracle__get_empty_subquery_sql(sql) }}
  {% endcall %}
  {%- set columns_result = load_result('get_columns') -%}
  {%- set column_names = columns_result.table.column_names -%}

  {# Create a temporary table with the data #}
  {%- set tmp_identifier = identifier ~ '__ext_tmp' -%}
  {%- set tmp_relation = api.Relation.create(identifier=tmp_identifier,
                                              schema=schema,
                                              database=database,
                                              type='table') -%}

  {# Drop temp table if exists #}
  {{ drop_relation_if_exists(tmp_relation) }}

  {# Step 3: Create temp table with the model data #}
  {% call statement('create_temp_table') %}
    {{ oracle__create_table_as(False, tmp_relation, sql) }}
  {% endcall %}

  {# Step 4: Export data to CSV using PL/SQL with UTL_FILE #}
  {% call statement('export_to_csv') %}
    {{ oracle__export_table_to_csv(tmp_relation, directory_name, csv_file_name, column_names, field_delimiter) }}
  {% endcall %}

  {# Step 5: Create the external table #}
  {% call statement('main') %}
    {{ oracle__create_external_table(target_relation, directory_name, csv_file_name, column_names, field_delimiter, line_terminator, skip_headers, encoding) }}
  {% endcall %}

  {# Clean up temporary table #}
  {{ drop_relation_if_exists(tmp_relation) }}

  {% do persist_docs(target_relation, model) %}

  {{ run_hooks(post_hooks, inside_transaction=True) }}

  {{ adapter.commit() }}

  {{ run_hooks(post_hooks, inside_transaction=False) }}

  {% set should_revoke = should_revoke(old_relation, full_refresh_mode=True) %}
  {% do apply_grants(target_relation, grant_config, should_revoke=should_revoke) %}

  {{ return({'relations': [target_relation]}) }}

{% endmaterialization %}


{# Macro to create Oracle directory if it doesn't exist #}
{% macro oracle__create_directory_if_not_exists(directory_name, directory_path) %}
  DECLARE
    dir_exists NUMBER;
  BEGIN
    SELECT COUNT(*) INTO dir_exists
    FROM all_directories
    WHERE directory_name = UPPER('{{ directory_name }}');

    IF dir_exists = 0 THEN
      EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY {{ directory_name }} AS ''{{ directory_path }}''';
    END IF;
  END;
{% endmacro %}


{# Macro to export table data to CSV using UTL_FILE #}
{% macro oracle__export_table_to_csv(relation, directory_name, csv_file_name, column_names, field_delimiter) %}
  DECLARE
    v_file UTL_FILE.FILE_TYPE;
    v_line VARCHAR2(32767);
  BEGIN
    -- Open file for writing
    v_file := UTL_FILE.FOPEN(UPPER('{{ directory_name }}'), '{{ csv_file_name }}', 'W', 32767);

    -- Write header row
    v_line := '{{ column_names | join(field_delimiter) }}';
    UTL_FILE.PUT_LINE(v_file, v_line);

    -- Write data rows
    FOR rec IN (SELECT * FROM {{ relation }}) LOOP
      v_line := {% for col in column_names %}{% if not loop.first %} || '{{ field_delimiter }}' || {% endif %}NVL(TO_CHAR(rec.{{ col }}), ''){% endfor %};
      UTL_FILE.PUT_LINE(v_file, v_line);
    END LOOP;

    -- Close file
    UTL_FILE.FCLOSE(v_file);
  EXCEPTION
    WHEN OTHERS THEN
      IF UTL_FILE.IS_OPEN(v_file) THEN
        UTL_FILE.FCLOSE(v_file);
      END IF;
      RAISE;
  END;
{% endmacro %}


{# Macro to create external table #}
{% macro oracle__create_external_table(relation, directory_name, csv_file_name, column_names, field_delimiter, line_terminator, skip_headers, encoding) %}
  CREATE TABLE {{ relation }} (
    {% for col in column_names %}
      {{ col }} VARCHAR2(4000){% if not loop.last %},{% endif %}
    {% endfor %}
  )
  ORGANIZATION EXTERNAL (
    TYPE ORACLE_LOADER
    DEFAULT DIRECTORY {{ directory_name }}
    ACCESS PARAMETERS (
      RECORDS DELIMITED BY {{ line_terminator }}
      CHARACTERSET {{ encoding }}
      SKIP {{ skip_headers }}
      FIELDS TERMINATED BY '{{ field_delimiter }}'
      OPTIONALLY ENCLOSED BY '"'
      MISSING FIELD VALUES ARE NULL
      (
        {% for col in column_names %}
          {{ col }} CHAR(4000){% if not loop.last %},{% endif %}
        {% endfor %}
      )
    )
    LOCATION ('{{ csv_file_name }}')
  )
  REJECT LIMIT UNLIMITED
{% endmacro %}
