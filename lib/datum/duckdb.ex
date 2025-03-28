defmodule Datum.Duckdb do
  @dialyzer {:nowarn_function, init: 1}
  @moduledoc """
  DuckDB is a GenServer (https://hexdocs.pm/elixir/GenServer.html) which is in charge of running any queries on
  CSV and Parquet files currently. Each instance of this GenServer is an individual DB, interacting with a single
  user through a LiveView.

  Also, _all_ interactions with this genserver should be done asynchronously so that we avoid the application
  hanging while waiting for a db's response, as those could be time consuming depending on hardware and
  load. The db should require a parent pid on init, and then send replies back to that pid on messgages
  it generates.

  Because messages copy all data back and forth, the initial workup of this genserver will send results back
  as a message BUT we will need to find a better way to handle results - such as uploading those results
  to the origin alongside the files.
  """
  use GenServer
  require Logger

  # parent is required as the communication is async
  def start_link(default, opts \\ []) do
    GenServer.start_link(__MODULE__, default, opts)
  end

  @doc """
  Send query will take a user's provided text query and then send it to
  the database connection. This is an async task - replies should be listened for.
  Provide a reference so that you know what reply a message is for
  """
  def query(pid, query, opts \\ []) do
    GenServer.cast(pid, {:query, query, opts})
  end

  def query_sync(pid, query) do
    GenServer.call(pid, {:query, query}, :infinity)
  end

  def result_to_df(result) do
    Adbc.Result.materialize(result) |> Adbc.Result.to_map() |> Explorer.DataFrame.new()
  end

  # Server
  @impl true
  def init(state) do
    path = Map.get(state, :path, ":memory:")

    access_mode =
      case Map.get(state, :access_mode, :read_write) do
        :read_write -> "READ_WRITE"
        :read_only -> "READ_ONLY"
      end

    # open a connection to the db when you need to use it, connections are
    # native OS threads - not processes!
    case Adbc.Database.start_link(
           driver: :duckdb,
           path: "#{path}",
           access_mode: access_mode
         ) do
      {:ok, db} ->
        {:ok, state |> Map.put(:db, db)}

      _ ->
        {:stop, "unable to open DuckDB"}
    end
  end

  @impl true
  def handle_cast({:query, query, opts}, state) do
    msg_id = Keyword.get(opts, :id, UUID.uuid4())

    with {:ok, conn} <- Adbc.Connection.start_link(database: state.db),
         {:ok, result} <- Adbc.Connection.query(conn, query) do
      send(
        state.parent,
        {:query_response,
         %{
           id: msg_id,
           result: result
         }}
      )

      GenServer.stop(conn, :normal)
    else
      error ->
        send(
          state.parent,
          {:error,
           %{
             id: msg_id,
             error: error
           }}
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:query, query}, _from, state) do
    with {:ok, conn} <- Adbc.Connection.start_link(database: state.db),
         {:ok, result} <- Adbc.Connection.query(conn, query) do
      GenServer.stop(conn, :normal)

      {:reply, {:ok, result}, state}
    else
      error -> {:reply, {:error, error}, state}
    end
  end

  # adding files as a table in the current duckdb instance - the origin will be
  # fetched in order to find and get access to the file(s) through the config
  # locations is a list of the original location of the files, not their location
  # inside the hierarchy - debated on whether or not to accept the full Origin
  # but want to minimize the amount of shared code in this module
  #
  # you can pass in a specific file extension by sending an optional param
  # :extension - this will short-circuit automatic detection and load the requested
  # duckdb extension, currently supported :parquet, :csv, and :json
  # NOTE: if including multiple locations, you must make sure they're all the same
  # kind of files
  @impl true
  def handle_call(
        {:add_data, config, locations, opts},
        _from,
        state
      ) do
    override_ext = Keyword.get(opts, :extension)
    table_name = Keyword.get(opts, :table_name, "file")

    extensions =
      locations
      |> Enum.map(fn location -> MIME.from_path(location) |> MIME.extensions() end)
      |> List.flatten()

    extension =
      if override_ext do
        override_ext
      else
        cond do
          Enum.any?(extensions, fn extension -> extension == "parquet" end) ->
            :parquet

          Enum.any?(extensions, fn extension -> extension == "csv" end) ->
            :csv

          Enum.any?(extensions, fn extension -> extension == "json" end) ->
            :json

          true ->
            :none
        end
      end

    with :ok <- load_secret(config, state.db),
         :ok <- load_files(extension, locations, table_name, state.db) do
      {:reply, :ok, state}
    else
      error -> {:reply, {:error, error}, state}
    end
  end

  # this is the only part of the module that references code in the greater module
  # it was just easier to do the pattern matching for the config based on real
  # configs
  #
  # https://duckdb.org/docs/extensions/httpfs/s3api.html
  defp load_secret(%Datum.DataOrigin.Origin.S3Config{} = config, db) do
    query = """
    CREATE SECRET secret#{:rand.uniform(99)} (
    TYPE S3,
    KEY_ID '#{config.access_key_id}',
    SECRET '#{config.secret_access_key}',
    REGION  '#{config.region}',
    ENDPOINT '#{Map.get(config, :endpoint, "s3.amazonaws.com")}',
    SCOPE '#{config.bucket}'
    );
    """

    with {:ok, conn} <- Adbc.Connection.start_link(database: db),
         {:ok, _result} <- Adbc.Connection.query(conn, query) do
      :ok
    else
      error -> {:error, error}
    end
  end

  # https://duckdb.org/docs/guides/network_cloud_storage/cloudflare_r2_import.html
  defp load_secret(%Datum.DataOrigin.Origin.R2Config{} = config, db) do
    query = """
    CREATE SECRET secret#{:rand.uniform(99)} (
    TYPE R2,
    KEY_ID '#{config.key_id}',
    SECRET '#{config.secret}',
    ACCOUNT_ID '#{config.account_id}',
    );
    """

    with {:ok, conn} <- Adbc.Connection.start_link(database: db),
         {:ok, _} <- Adbc.Connection.query(conn, "INSTALL 'httpfs';"),
         {:ok, _} <- Adbc.Connection.query(conn, "LOAD 'httpfs';"),
         {:ok, _result} <- Adbc.Connection.query(conn, query) do
      :ok
    else
      error -> {:error, error}
    end
  end

  # https://duckdb.org/docs/extensions/azure.html#authentication-with-secret
  defp load_secret(%Datum.DataOrigin.Origin.AzureConfig{} = config, db) do
    query = """
    CREATE SECRET secret#{:rand.uniform(99)} (
    TYPE AZURE,
    CONNECTION_STRING '#{config.connection_string}',
    SCOPE '#{config.container}',
    );
    """

    with {:ok, conn} <- Adbc.Connection.start_link(database: db),
         {:ok, _} <- Adbc.Connection.query(conn, "INSTALL 'azure';"),
         {:ok, _} <- Adbc.Connection.query(conn, "LOAD 'azure';"),
         {:ok, _result} <- Adbc.Connection.query(conn, query) do
      :ok
    else
      error -> {:error, error}
    end
  end

  # we don't actually need to anything for this right now, just return :ok
  defp load_secret(%Datum.DataOrigin.Origin.FilesystemConfig{} = _config, _db) do
    :ok
  end

  # these are the functions for actually loading the files at tables - the final option
  # is for running the statement without the specific read statements - might not work
  defp load_files(:csv, locations, table_name, db) do
    with {:ok, conn} <- Adbc.Connection.start_link(database: db),
         {:ok, _result} <-
           Adbc.Connection.query(
             conn,
             "CREATE TABLE #{table_name} AS SELECT * FROM read_csv([#{Enum.map_join(locations, ",", fn location -> ~s("#{location}") end)}]);"
           ) do
      :ok
    else
      error -> {:error, error}
    end
  end

  defp load_files(:parquet, locations, table_name, db) do
    with {:ok, conn} <- Adbc.Connection.start_link(database: db),
         {:ok, _} <- Adbc.Connection.query(conn, "INSTALL 'parquet';"),
         {:ok, _} <- Adbc.Connection.query(conn, "LOAD 'parquet';"),
         {:ok, _result} <-
           Adbc.Connection.query(
             conn,
             "CREATE TABLE #{table_name} AS SELECT * FROM read_parquet([#{Enum.map_join(locations, ",", fn location -> ~s("#{location}") end)}]);"
           ) do
      :ok
    else
      error -> {:error, error}
    end
  end

  defp load_files(:json, locations, table_name, db) do
    with {:ok, conn} <- Adbc.Connection.start_link(database: db),
         {:ok, _} <- Adbc.Connection.query(conn, "INSTALL 'json';"),
         {:ok, _} <- Adbc.Connection.query(conn, "LOAD 'json';"),
         {:ok, _result} <-
           Adbc.Connection.query(
             conn,
             "CREATE TABLE #{table_name} AS SELECT * FROM read_json([#{Enum.map_join(locations, ",", fn location -> ~s("#{location}") end)}]);"
           ) do
      :ok
    else
      error -> {:error, error}
    end
  end

  # if the file doesn't meet requirements for the specific scanner, its why its the last
  defp load_files(_none, locations, table_name, db) do
    if Enum.count(locations) > 1 do
      {:error, "too many files for extension type"}
    else
      with {:ok, conn} <- Adbc.Connection.start_link(database: db),
           {:ok, _result} <-
             Adbc.Connection.query(
               conn,
               "CREATE TABLE #{table_name} AS SELECT * FROM '#{List.first(locations)}';"
             ) do
        :ok
      else
        error -> {:error, error}
      end
    end
  end
end
