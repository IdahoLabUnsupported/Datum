import Config

# Note we also include the path to a cache manifest
# containing the digested version of static files. This
# manifest is generated by the `mix assets.deploy` task,
# which you should run after static files are built and
# before starting your production server.
config :datum, DatumWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  origin_db_path: Path.join([System.user_home(), ".datum_databases", "origins"])

# Configures Swoosh API Client
config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Datum.Finch

# Disable Swoosh Local Memory Storage
config :swoosh, local: false

# Do not print debug messages in production
config :logger, level: :info

if System.get_env("DOCKER_BUILD", "FALSE") |> String.upcase() === "TRUE" do
  config :datum, Datum.Plugins.HDF5,
    crate: :hdf5_extractor,
    skip_compilation?: true,
    load_from: {:datum, "priv/native/libhdf5_extractor"}
end

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
