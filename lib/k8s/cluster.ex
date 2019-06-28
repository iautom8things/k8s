defmodule K8s.Cluster do
  @moduledoc """
  Cluster configuration and API route store for `K8s.Client`
  """

  @discovery Application.get_env(:k8s, :discovery_provider, K8s.Discovery)

  @doc """
  Register a new cluster to use with `K8s.Client`

  ## Examples

      iex> conf = K8s.Conf.from_file("./test/support/kube-config.yaml")
      ...> :test_cluster = K8s.Cluster.register(:test_cluster, conf)
      :test_cluster

  """
  @spec register(atom, K8s.Conf.t()) :: atom
  def register(cluster_name, conf) do
    {duration, _result} =
      :timer.tc(fn ->
        :ets.insert(K8s.Conf, {cluster_name, conf})
        groups = @discovery.resource_definitions_by_group(cluster_name)

        Enum.each(groups, fn %{"groupVersion" => gv, "resources" => rs} ->
          cluster_group_key = K8s.Group.cluster_key(cluster_name, gv)
          :ets.insert(K8s.Group, {cluster_group_key, gv, rs})
        end)
      end)

    K8s.Sys.Event.cluster_registered(%{duration: duration}, %{name: cluster_name})
    cluster_name
  end

  @doc """
  Retrieve the URL for a `K8s.Operation`

  ## Examples

      iex> conf = K8s.Conf.from_file("./test/support/kube-config.yaml")
      ...> K8s.Cluster.register(:test_cluster, conf)
      ...> operation = K8s.Operation.build(:get, "apps/v1", :deployment, [namespace: "default", name: "nginx"])
      ...> K8s.Cluster.url_for(operation, :test_cluster)
      {:ok, "https://localhost:6443/apis/apps/v1/namespaces/default/deployments/nginx"}

  """
  @spec url_for(K8s.Operation.t(), atom) :: {:ok, binary} | {:error, atom} | {:error, binary}
  def url_for(%K8s.Operation{} = operation, cluster_name) do
    %{group_version: group_version, kind: kind, verb: verb} = operation
    {:ok, conf} = K8s.Cluster.conf(cluster_name)

    with {:ok, resource} <- K8s.Group.find_resource(cluster_name, group_version, kind),
         {:ok, path} <- K8s.Path.build(group_version, resource, verb, operation.path_params) do
      {:ok, Path.join(conf.url, path)}
    else
      error -> error
    end
  end

  @doc """
  Retrieve the base URL for a cluster

  ## Examples

      iex> conf = K8s.Conf.from_file("./test/support/kube-config.yaml")
      ...> K8s.Cluster.register(:test_cluster, conf)
      ...> K8s.Cluster.base_url(:test_cluster)
      {:ok, "https://localhost:6443"}
  """
  @spec base_url(atom) :: {:ok, binary()} | {:error, atom} | {:error, binary}
  def base_url(cluster_name) do
    with {:ok, conf} <- K8s.Cluster.conf(cluster_name) do
      {:ok, conf.url}
    end
  end

  @doc """
  Registers clusters automatically from `config.exs`

  ## Examples

  By default a cluster will attempt to use the ServiceAccount assigned to the pod:

  ```elixir
  config :k8s,
    clusters: %{
      default: %{}
    }
  ```

  Configuring a cluster using a k8s config:

  ```elixir
  config :k8s,
    clusters: %{
      default: %{
        conf: "~/.kube/config"
        conf_opts: [user: "some-user", cluster: "prod-cluster"]
      }
    }
  ```
  """
  def register_clusters do
    clusters = K8s.Config.clusters()

    Enum.each(clusters, fn {name, details} ->
      conf =
        case Map.get(details, :conf) do
          nil ->
            K8s.Conf.from_service_account()

          %{use_sa: true} ->
            K8s.Conf.from_service_account()

          conf_path ->
            opts = details[:conf_opts] || []
            K8s.Conf.from_file(conf_path, opts)
        end

      K8s.Cluster.register(name, conf)
    end)

    clusters
  end

  @doc """
  Retrieve a cluster's connection configuration.

  ## Example

      iex> config_file = K8s.Conf.from_file("./test/support/kube-config.yaml", [user: "token-user"])
      ...> K8s.Cluster.register(:test_cluster, config_file)
      ...> {:ok, conf} = K8s.Cluster.conf(:test_cluster)
      ...> conf
      %K8s.Conf{auth: %K8s.Conf.Auth.Token{token: "just-a-token-user-pun-intended"}, ca_cert: nil, cluster_name: "docker-for-desktop-cluster", insecure_skip_tls_verify: true, url: "https://localhost:6443",user_name: "token-user"}
  """
  @spec conf(atom) :: {:ok, K8s.Conf.t()} | {:error, :cluster_not_registered}
  def conf(cluster_name) do
    case :ets.lookup(K8s.Conf, cluster_name) do
      [] -> {:error, :cluster_not_registered}
      [{_, conf}] -> {:ok, conf}
    end
  end

  @doc """
  List registered cluster names
  """
  @spec list() :: list(atom)
  def list() do
    K8s.Conf
    |> :ets.tab2list()
    |> Keyword.keys()
  end
end
