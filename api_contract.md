## GET /origins

- use this endpoint to get the origin name for the equipment - can hardcode it to be "Facility Equipment" or whatever, just let me know ahead of time.

```
[
    {
        "id": "ORIGIN UUID",
        "name": "ORIGIN NAME"
    }
]
```

## GET /origins/{origin_uuid}/data

- this lists everything at the root directory - you will get a list of data back, each one representing a piece of equipment
- what you want is the relationships - find ones that are the daqs - these should point to a duckdb table.

```
[
    {
        "id": "EQUIPMENT UUID",
        "path": "EQUIPMENT NODE NAME FROM UNITY",
        "type": "file",
        ......
        "properties": {
            "name": "EQUIPMENT NODE NAME FROM UNITY"
        },
        incoming_relationships: [[sensor_uuid, origin_uuid, "daq column name"]],
        outgoing_relationships: [[sensor_uuid, origin_uuid, "daq column name"]] 
    }
]
```

## GET /origins/{origin_uuid}/data/{sensor_uuid}

Information about the daq in properties. This represents a table in the underlying DuckDB db - each table is a DAQ and each column is a sensor/channel.
The relationships these have point out to various .pgg files with graphs. The relationship will have which sensor the graph belongs to. Use the `inserted_at` timestamp to sort.

```
   {
        "id": "DATA UUID",
        "origin_id": "origin uuid"
        "path": "table_name"
        "type": "table", 
        "properties": {
            ..... # dependent on daq
            it _should_ be an object with the following
            "columns": {
                "column_name": "column_type"
            }
        },
        incoming_relationships: [[graph_uuid, origin_uuid, "daq column name"]],
    }
```


## POST /origin/{origin_uuid}/explore

BODY
```
{
    "query": "ANY VALID SQL QUERY"
}
```

- origin_uuid is the origin_id from the table record
- run the query `SHOW TABLES` to get a list of all tables - *but you don't need to do this* you can use the `path` from the record above which is the table name AND column name you need to query

```
[
    ["table_name"],
    ["table1"],
    ["table2"],
]
```

- run the query `DESCRIBE {table_name}` to get a list of all the columns and types - in this case represents the channel names, but you can also look at the properties of the table data record


```
[
    ["column_name", "column_type"],
    ["timestamp", "TIMESTAMP"]
    ["ai01", "INTEGER"],
    ["ai02", "FLOAT"],
]
```

- run the query `SELECT */column name FROM {table_name} LIMIT 10` to dump data - always pass a limit so we don't swamp the headset

```
[
    {
    "name":"access_mode",
    "value":"read_only",
    "description":"Access mode of the database (AUTOMATIC, READ_ONLY or READ_WRITE)",
    "input_type":"VARCHAR",
    "scope":"GLOBAL"
    }
]
```

## GET /origin/{origin_uuid}/data/{graph_uuid}/download
- if we have access to the file, this will attempt to download and return it to the caller
- this will download the PNG
