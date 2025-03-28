defmodule Datum.DataOrigin do
  @moduledoc """
  The DataOrigin context. See data_origin/Origin.ex for information on what a DataOrigin is
  and how it slots into the bigger picture of Datum.
  """

  import Ecto.Query, warn: false
  alias Datum.DataOrigin.DataSearch
  alias Datum.DataOrigin.DataTreePath
  alias Datum.Repo
  alias Datum.DataOrigin.OriginRepo

  alias Datum.DataOrigin.Origin
  alias Datum.DataOrigin.Data
  alias Datum.Accounts.User
  alias Datum.Accounts.UserGroup

  @doc """
  Returns the list of data_origins.

  ## Examples

      iex> list_data_origins()
      [%Origin{}, ...]

  """
  def list_data_origins do
    Repo.all(Origin)
  end

  @doc """
  Returns a list of data_origins for a user - taking into account
  their groups and permissions for said origins.
  """
  def list_data_orgins_user(%User{} = user, exclude \\ [], opts \\ []) do
    permissions = Keyword.get(opts, :permissions, [:read, :readwrite])

    query =
      from o in Origin,
        distinct: true,
        left_join: p in Datum.Permissions.DataOrigin,
        on: o.id == p.data_origin_id,
        where:
          (p.user_id == ^user.id or
             p.group_id in subquery(
               from g in UserGroup, where: g.user_id == ^user.id, select: g.group_id
             )) and p.permission_type in ^permissions and o.id not in ^exclude,
        select: o

    Repo.all(query)
  end

  def get_data_orgins_user(%User{} = user, origin_id, opts \\ []) when not is_nil(origin_id) do
    permissions = Keyword.get(opts, :permissions, [:read, :readwrite])

    query =
      from o in Origin,
        distinct: true,
        left_join: p in Datum.Permissions.DataOrigin,
        on: o.id == p.data_origin_id,
        where:
          (p.user_id == ^user.id or
             p.group_id in subquery(
               from g in UserGroup, where: g.user_id == ^user.id, select: g.group_id
             )) and p.permission_type in ^permissions and o.id == ^origin_id,
        select: o

    Repo.one(query)
  end

  def get_data_orgins_user!(%User{} = user, origin_id, opts \\ []) when not is_nil(origin_id) do
    permissions = Keyword.get(opts, :permissions, [:read, :readwrite])

    query =
      from o in Origin,
        distinct: true,
        left_join: p in Datum.Permissions.DataOrigin,
        on: o.id == p.data_origin_id,
        where:
          (p.user_id == ^user.id or
             p.group_id in subquery(
               from g in UserGroup, where: g.user_id == ^user.id, select: g.group_id
             )) and p.permission_type in ^permissions and o.id == ^origin_id,
        select: o

    Repo.one!(query)
  end

  @doc """
  Gets a single origin.

  Raises `Ecto.NoResultsError` if the Origin does not exist.

  ## Examples

      iex> get_origin!(123)
      %Origin{}

      iex> get_origin!(456)
      ** (Ecto.NoResultsError)

  """
  def get_origin!(id), do: Repo.get!(Origin, id)

  @doc """
  Creates a origin.

  ## Examples

      iex> create_origin(%{field: value})
      {:ok, %Origin{}}

      iex> create_origin(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_origin(attrs \\ %{}) do
    with {:ok, origin} <-
           %Origin{}
           |> Origin.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing),
         {:ok, _perm} <-
           Datum.Permissions.create_data_origin(%{
             data_origin_id: origin.id,
             user_id: origin.owned_by,
             permission_type: :readwrite
           }),
         {:ok, updated_origin} <-
           update_origin(origin, %{
             database_path:
               Path.join(
                 Application.get_env(:datum, :origin_db_path),
                 "#{ShortUUID.encode!(origin.id)}.db"
               )
           }) do
      # connecting to data origin record to establish database
      Datum.DataOrigin.OriginRepo.with_dynamic_repo(
        updated_origin,
        fn -> {:ok, updated_origin} end,
        mode: :readwrite
      )
    else
      err -> err
    end
  end

  @doc """
  Updates a origin.

  ## Examples

      iex> update_origin(origin, %{field: new_value})
      {:ok, %Origin{}}

      iex> update_origin(origin, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_origin(%Origin{} = origin, attrs) do
    origin
    |> Origin.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a origin.

  ## Examples

      iex> delete_origin(origin)
      {:ok, %Origin{}}

      iex> delete_origin(origin)
      {:error, %Ecto.Changeset{}}

  """
  def delete_origin(%Origin{} = origin) do
    with :ok <- File.rm(origin.database_path),
         {:ok, %Origin{}} <- Repo.delete(origin) do
      {:ok, %Origin{}}
    else
      _ -> :error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking origin changes.

  ## Examples

      iex> change_origin(origin)
      %Ecto.Changeset{data: %Origin{}}

  """
  def change_origin(%Origin{} = origin, attrs \\ %{}) do
    Origin.changeset(origin, attrs)
  end

  def add_data(%Origin{} = origin, %User{} = user, attrs \\ %{}) do
    OriginRepo.with_dynamic_repo(origin, fn ->
      with {:ok, data} <-
             %Data{}
             |> Data.changeset(attrs)
             |> Ecto.Changeset.put_change(:origin_id, origin.id)
             |> OriginRepo.insert(
               on_conflict:
                 {:replace,
                  [
                    :properties,
                    :owned_by,
                    :checksum_type,
                    :checksum
                  ]},
               returning: true
             ),
           {:ok, _perm} <-
             %Datum.Permissions.Data{}
             |> Datum.Permissions.Data.changeset(%{
               data_id: data.id,
               user_id: user.id,
               permission_type: :readwrite
             })
             |> OriginRepo.insert() do
        {:ok, data}
      else
        err ->
          {:error, err}
      end
    end)
  end

  def add_data!(%Origin{} = origin, %User{} = user, attrs \\ %{}) do
    OriginRepo.with_dynamic_repo(origin, fn ->
      with %Data{} = data <-
             %Data{}
             |> Data.changeset(Map.put(attrs, :origin_id, origin.id))
             |> OriginRepo.insert!(
               on_conflict:
                 {:replace_all_except,
                  [
                    :id,
                    :tags,
                    :domains,
                    :incoming_relationships,
                    :outgoing_relationships
                  ]}
             ),
           %Datum.Permissions.Data{} = _perm <-
             %Datum.Permissions.Data{}
             |> Datum.Permissions.Data.changeset(%{
               data_id: data.id,
               user_id: user.id,
               permission_type: :readwrite
             })
             |> OriginRepo.insert!() do
        data
      else
        err -> {:error, err}
      end
    end)
  end

  # this is the connection for data within a single origin, typically how we represent
  # the filesystem heirarchy. If you're looking for cross-origin relationships, or just
  # general relationships without modifying the filesystem, look at add_relationship/3
  def connect_data(%Origin{} = origin, %Data{} = ancestor, %Data{} = leaf) do
    OriginRepo.with_dynamic_repo(origin, fn ->
      Datum.DataOrigin.CT.insert(leaf.id, ancestor.id)
    end)
  end

  def get_data_user(%Origin{} = origin, %User{} = user, data_id, opts \\ []) do
    permissions = Keyword.get(opts, :permissions, [:read, :readwrite])

    groups =
      Repo.all(
        from g in UserGroup,
          where: g.user_id == ^user.id,
          select: g.group_id
      )

    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        query =
          from d in Data,
            distinct: true,
            left_join: p in Datum.Permissions.Data,
            on: d.id == p.data_id,
            where:
              (p.user_id == ^user.id or
                 p.group_id in ^groups) and p.permission_type in ^permissions and
                d.id == ^data_id,
            select: d

        OriginRepo.one(query)
      end,
      mode: :readonly
    )
  end

  def get_data_user!(%Origin{} = origin, %User{} = user, data_id, opts \\ []) do
    permissions = Keyword.get(opts, :permissions, [:read, :readwrite])

    groups =
      Repo.all(
        from g in UserGroup,
          where: g.user_id == ^user.id,
          select: g.group_id
      )

    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        query =
          from d in Data,
            distinct: true,
            left_join: p in Datum.Permissions.Data,
            on: d.id == p.data_id,
            where:
              (p.user_id == ^user.id or
                 p.group_id in ^groups) and p.permission_type in ^permissions and
                d.id == ^data_id,
            select: d

        OriginRepo.one!(query)
      end,
      mode: :readonly
    )
  end

  def get_data!(%Origin{} = origin, data_id) do
    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        OriginRepo.get!(Data, data_id)
      end,
      mode: :readonly
    )
  end

  def delete_data(%Origin{} = origin, data) do
    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        OriginRepo.delete(data)
      end,
      mode: :readwrite
    )
  end

  def get_data_by_path!(%Origin{} = origin, path) do
    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        query =
          from d in Data,
            where: d.path == ^path,
            select: d

        OriginRepo.one(query)
      end,
      mode: :readonly
    )
  end

  # add relationship will attempt to update the data record on both supplied origins with
  # information about the other, creating a linkagae between the two. Options are available
  # for supplying a type to the relationship and eventually, hopefully, validating it against
  # an ontology. Note: the relationships are not updated from storage before being appended
  # permissions should happen before this
  def add_relationship(
        {%Data{} = o_data, %Origin{} = o_origin} = _origin,
        {%Data{} = d_data, %Origin{} = d_origin} = _destination,
        opts \\ []
      ) do
    relationship_type = Keyword.get(opts, :type, "")

    o_result =
      OriginRepo.with_dynamic_repo(
        o_origin,
        fn ->
          result =
            o_data
            |> Data.changeset(%{
              outgoing_relationships: [
                [d_data.id, d_origin.id, relationship_type]
                | o_data.incoming_relationships
              ]
            })
            |> OriginRepo.update()

          case result do
            {:ok, _r} ->
              if o_origin.id == d_origin.id do
                d_data
                |> Data.changeset(%{
                  incoming_relationships: [
                    [o_data.id, o_origin.id, relationship_type]
                    | d_data.incoming_relationships
                  ]
                })
                |> OriginRepo.update()
              else
                result
              end

            _ ->
              result
          end
        end,
        mode: :readwrite
      )

    if o_origin.id == d_origin.id do
      o_result
    else
      OriginRepo.with_dynamic_repo(
        d_origin,
        fn ->
          d_data
          |> Data.changeset(%{
            incoming_relationships: [
              [o_data.id, o_origin.id, relationship_type]
              | d_data.incoming_relationships
            ]
          })
          |> OriginRepo.update()
        end,
        mode: :readwrite
      )
    end
  end

  def list_data_user(%Origin{} = origin, %User{} = user, opts \\ []) do
    only_ids = Keyword.get(opts, :only_ids)
    permissions = Keyword.get(opts, :permissions, [:read, :readwrite])

    groups =
      Repo.all(
        from g in UserGroup,
          where: g.user_id == ^user.id,
          select: g.group_id
      )

    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        query =
          from d in Data,
            distinct: true,
            left_join: p in Datum.Permissions.Data,
            on: d.id == p.data_id,
            where:
              (p.user_id == ^user.id or
                 p.group_id in ^groups) and p.permission_type in ^permissions,
            select: d

        query =
          if only_ids do
            from d in query, where: d.id in ^only_ids
          else
            query
          end

        OriginRepo.all(query)
      end,
      mode: :readonly
    )
  end

  def list_data_descendants(%Origin{} = origin, data_id) do
    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        query =
          from d in Data,
            join: p in DataTreePath,
            as: :tree,
            on: d.id == p.descendant,
            where: p.ancestor == ^data_id and p.descendant != p.ancestor,
            order_by: [asc: p.depth],
            select: d.id

        OriginRepo.all(query)
      end,
      mode: :readonly
    )
  end

  def list_data_descendants_user(%Origin{} = origin, %User{} = user, data_id, opts \\ []) do
    permissions = Keyword.get(opts, :permissions, [:read, :readwrite])
    depth = Keyword.get(opts, :depth, 1)

    groups =
      Repo.all(
        from g in UserGroup,
          where: g.user_id == ^user.id,
          select: g.group_id
      )

    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        subquery =
          from d in Data,
            join: p in DataTreePath,
            as: :tree,
            on: d.id == p.descendant,
            where: p.ancestor == ^data_id and p.descendant != p.ancestor and p.depth <= ^depth,
            order_by: [asc: p.depth],
            select: d.id

        query =
          from d in Data,
            distinct: true,
            left_join: p in Datum.Permissions.Data,
            on: d.id == p.data_id,
            where:
              (p.user_id == ^user.id or
                 p.group_id in ^groups) and p.permission_type in ^permissions and
                d.id in subquery(subquery),
            order_by: [asc: d.type],
            select: d

        OriginRepo.all(query)
      end,
      mode: :readonly
    )
  end

  def list_roots(%Origin{type: :duckdb} = origin) do
    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        query =
          from d in Data,
            distinct: true,
            ## this marks a root file system in CTE
            where: d.type == :table

        OriginRepo.all(query)
      end,
      mode: :readonly
    )
  end

  def list_roots(%Origin{} = origin) do
    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        query =
          from d in Data,
            distinct: true,
            ## this marks a root file system in CTE
            where: d.type == :root_directory

        OriginRepo.all(query)
      end,
      mode: :readonly
    )
  end

  @page_size 10_000

  def search_origin(%Origin{} = origin, %Datum.Accounts.User{} = user, search_term, opts \\ []) do
    permissions = Keyword.get(opts, :permissions, [:read, :readwrite])

    groups =
      Repo.all(
        from g in Datum.Accounts.UserGroup,
          where: g.user_id == ^user.id,
          select: g.group_id
      )

    OriginRepo.with_dynamic_repo(
      origin,
      fn ->
        if search_term == "" do
          []
        else
          page = Keyword.get(opts, :page, 0)
          page_size = Keyword.get(opts, :page_size, @page_size)

          # dashes are interpreted as column filters, so we want to remove that
          search_term = String.replace(search_term, "-", "")
          lower = page_size * page
          upper = page_size * (page + 1)

          subquery =
            from d in Data,
              join: p in Datum.Permissions.Data,
              on: d.id == p.data_id,
              where:
                ((p.user_id == ^user.id or
                    p.group_id in ^groups) and p.permission_type in ^permissions) or
                  is_nil(p.user_id),
              select: d.id

          query =
            from ds in DataSearch,
              join: d in Data,
              on: ds.id == d.id,
              where:
                fragment(
                  "data_search MATCH (?)",
                  ^search_term
                ) and d.id in subquery(subquery),
              order_by: fragment("bm25(data_search,1.0, 5.0, 5.0,7.0,7.0,8.0,9.0,9.0,9.0)"),
              select: %{
                d
                | description_snippet:
                    fragment("""
                    snippet(data_search,3,'', '',',', 64)
                    """),
                  natural_language_properties_snippet:
                    fragment("""
                    snippet(data_search,5,'', '',',', 64)
                    """)
              }

          outter =
            from q in subquery(query),
              select: %{
                q
                | row_num:
                    row_number()
                    |> over(),
                  count: count() |> over()
              }

          OriginRepo.all(
            from q in subquery(outter),
              where: q.row_num > ^lower and q.row_num <= ^upper,
              select: q
          )
        end
      end,
      mode: :readonly
    )
    # allows us to use the operational repo and load the results origins in one call
    |> Repo.preload(:origin)
  end

  @doc """
  This allows users to run queries on the data origin itself if they support it - such as
  running SQL queries on DuckDB backed origins, or exposed commands on the file system.


  Note - this only functions if the origin is a supported type _and_ its config field is not
  nil, indicating that it's a data backed origin we have connection info on
  """
  def query_origin_sync(origin, query, opts \\ [])

  #  WE DO NOT CARE ABOUT SQL INJECTION HERE BECAUSE WE'RE READ_ONLY
  def query_origin_sync(%Origin{type: :duckdb} = origin, query, _opts)
      when is_map(origin.config) do
    case Datum.Duckdb.start_link(%{path: origin.config["path"], access_mode: :read_only}) do
      {:ok, pid} -> Datum.Duckdb.query_sync(pid, query)
      {:error, {:already_started, pid}} -> Datum.Duckdb.query_sync(pid, query)
      {:error, message} -> {:error, message}
    end
  end

  def query_origin_sync(_origin, _query, _opts) do
    {:error, :unsupported}
  end

  alias Datum.DataOrigin.ExtractedMetadata

  @doc """
  Returns the list of extracted_metadatas.

  ## Examples

      iex> list_extracted_metadatas()
      [%ExtractedMetadata{}, ...]

  """
  def list_extracted_metadatas do
    Repo.all(ExtractedMetadata)
  end

  @doc """
  Gets a single extracted_metadata.

  Raises `Ecto.NoResultsError` if the Extracted metadata does not exist.

  ## Examples

      iex> get_extracted_metadata!(123)
      %ExtractedMetadata{}

      iex> get_extracted_metadata!(456)
      ** (Ecto.NoResultsError)

  """
  def get_extracted_metadata!(id), do: Repo.get!(ExtractedMetadata, id)

  @doc """
  Creates a extracted_metadata.

  ## Examples

      iex> create_extracted_metadata(%{field: value})
      {:ok, %ExtractedMetadata{}}

      iex> create_extracted_metadata(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_extracted_metadata(attrs \\ %{}) do
    %ExtractedMetadata{}
    |> ExtractedMetadata.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a extracted_metadata.

  ## Examples

      iex> update_extracted_metadata(extracted_metadata, %{field: new_value})
      {:ok, %ExtractedMetadata{}}

      iex> update_extracted_metadata(extracted_metadata, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_extracted_metadata(%ExtractedMetadata{} = extracted_metadata, attrs) do
    extracted_metadata
    |> ExtractedMetadata.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a extracted_metadata.

  ## Examples

      iex> delete_extracted_metadata(extracted_metadata)
      {:ok, %ExtractedMetadata{}}

      iex> delete_extracted_metadata(extracted_metadata)
      {:error, %Ecto.Changeset{}}

  """
  def delete_extracted_metadata(%ExtractedMetadata{} = extracted_metadata) do
    Repo.delete(extracted_metadata)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking extracted_metadata changes.

  ## Examples

      iex> change_extracted_metadata(extracted_metadata)
      %Ecto.Changeset{data: %ExtractedMetadata{}}

  """
  def change_extracted_metadata(%ExtractedMetadata{} = extracted_metadata, attrs \\ %{}) do
    ExtractedMetadata.changeset(extracted_metadata, attrs)
  end
end
