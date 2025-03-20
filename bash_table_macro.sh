#!/bin/bash

query_result="
           column_name           |          data_type          | is_nullable
---------------------------------+-----------------------------+-------------
 id                              | integer                     | NO
 active                          | boolean                     | NO
 name                            | character varying           | YES
 created_at                      | timestamp without time zone | NO
 data                            | jsonb                       | YES
"

# Function to map PostgreSQL types to Diesel types
map_pg_to_diesel() {
  local pg_type=$1
  case $pg_type in
    integer) echo "Int4" ;;
    bigint) echo "Int8" ;;
    smallint) echo "Int2" ;;
    boolean) echo "Bool" ;;
    "character varying") echo "Varchar" ;;
    timestamp*) echo "Timestamp" ;;
    jsonb) echo "Jsonb" ;;
    json) echo "Json" ;;
    *) echo "Unknown" ;;
  esac
}

# Initialize the Diesel table definition
table_name="orders" # Change as needed
diesel_table="table! {
    $table_name (id) {
"

# Process the query result
while IFS='|' read -r column_name data_type is_nullable; do
  # Trim whitespace
  column_name=$(echo "$column_name" | xargs)
  data_type=$(echo "$data_type" | xargs)
  is_nullable=$(echo "$is_nullable" | xargs)

  # Skip header and separator lines
  if [[ -z "$column_name" || "$column_name" == "column_name" || "$column_name" =~ ^[-+]+$ ]]; then
    continue
  fi

  # Map PostgreSQL type to Diesel type
  diesel_type=$(map_pg_to_diesel "$data_type")

  # Add Nullable if column is nullable
  if [[ "$is_nullable" == "YES" ]]; then
    diesel_type="Nullable<$diesel_type>"
  fi

  # Append to Diesel table definition
  diesel_table+="        $column_name -> $diesel_type,\n"
done <<< "$query_result"

# Close the Diesel table definition
diesel_table+="    }
}"

# Output the Diesel table definition
echo -e "$diesel_table"

