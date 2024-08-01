defmodule Plausible.Ingestion.Event do
  @moduledoc """
  This module exposes the `build_and_buffer/1` function capable of
  turning %Plausible.Ingestion.Request{} into a series of events that in turn
  are uniformly either buffered in batches (to Clickhouse) or dropped
  (e.g. due to spam blocklist) from the processing pipeline.
  """
  use Plausible
  alias Plausible.Ingestion.Request
  alias Plausible.ClickhouseEventV2
  alias Plausible.Site.GateKeeper

  defstruct domain: nil,
            site: nil,
            clickhouse_event_attrs: %{},
            clickhouse_session_attrs: %{},
            clickhouse_event: nil,
            dropped?: false,
            drop_reason: nil,
            request: nil,
            salts: nil,
            changeset: nil

  @verification_user_agent Plausible.Verification.user_agent()

  @type drop_reason() ::
          :bot
          | :spam_referrer
          | GateKeeper.policy()
          | :invalid
          | :dc_ip
          | :site_ip_blocklist
          | :site_country_blocklist
          | :site_page_blocklist
          | :site_hostname_allowlist
          | :verification_agent

  @type t() :: %__MODULE__{
          domain: String.t() | nil,
          site: %Plausible.Site{} | nil,
          clickhouse_event_attrs: map(),
          clickhouse_session_attrs: map(),
          clickhouse_event: %ClickhouseEventV2{} | nil,
          dropped?: boolean(),
          drop_reason: drop_reason(),
          request: Request.t(),
          salts: map(),
          changeset: %Ecto.Changeset{}
        }

  @spec build_and_buffer(Request.t()) :: {:ok, %{buffered: [t()], dropped: [t()]}}
  def build_and_buffer(%Request{domains: domains} = request) do
    processed_events =
      if spam_referrer?(request) do
        for domain <- domains, do: drop(new(domain, request), :spam_referrer)
      else
        Enum.reduce(domains, [], fn domain, acc ->
          case GateKeeper.check(domain) do
            {:allow, site} ->
              processed =
                domain
                |> new(site, request)
                |> process_unless_dropped(pipeline())

              [processed | acc]

            {:deny, reason} ->
              [drop(new(domain, request), reason) | acc]
          end
        end)
      end

    {dropped, buffered} = Enum.split_with(processed_events, & &1.dropped?)
    {:ok, %{dropped: dropped, buffered: buffered}}
  end

  @spec telemetry_event_buffered() :: [atom()]
  def telemetry_event_buffered() do
    [:plausible, :ingest, :event, :buffered]
  end

  @spec telemetry_event_dropped() :: [atom()]
  def telemetry_event_dropped() do
    [:plausible, :ingest, :event, :dropped]
  end

  def telemetry_pipeline_step_duration() do
    [:plausible, :ingest, :pipeline, :step]
  end

  @spec emit_telemetry_buffered(t()) :: :ok
  def emit_telemetry_buffered(event) do
    :telemetry.execute(telemetry_event_buffered(), %{}, %{
      domain: event.domain,
      request_timestamp: event.request.timestamp
    })
  end

  @spec emit_telemetry_dropped(t(), drop_reason()) :: :ok
  def emit_telemetry_dropped(event, reason) do
    :telemetry.execute(telemetry_event_dropped(), %{}, %{
      domain: event.domain,
      reason: reason,
      request_timestamp: event.request.timestamp
    })
  end

  defp pipeline() do
    [
      drop_verification_agent: &drop_verification_agent/1,
      drop_datacenter_ip: &drop_datacenter_ip/1,
      drop_shield_rule_hostname: &drop_shield_rule_hostname/1,
      drop_shield_rule_page: &drop_shield_rule_page/1,
      drop_shield_rule_ip: &drop_shield_rule_ip/1,
      put_geolocation: &put_geolocation/1,
      drop_shield_rule_country: &drop_shield_rule_country/1,
      put_user_agent: &put_user_agent/1,
      put_basic_info: &put_basic_info/1,
      put_referrer: &put_referrer/1,
      put_utm_tags: &put_utm_tags/1,
      put_props: &put_props/1,
      put_revenue: &put_revenue/1,
      put_salts: &put_salts/1,
      put_user_id: &put_user_id/1,
      validate_clickhouse_event: &validate_clickhouse_event/1,
      register_session: &register_session/1,
      write_to_buffer: &write_to_buffer/1
    ]
  end

  defp process_unless_dropped(%__MODULE__{} = initial_event, pipeline) do
    Enum.reduce_while(pipeline, initial_event, fn {step_name, step_fn}, acc_event ->
      Plausible.PromEx.Plugins.PlausibleMetrics.measure_duration(
        telemetry_pipeline_step_duration(),
        fn -> execute_step(step_fn, acc_event) end,
        %{step: "#{step_name}"}
      )
    end)
  end

  defp execute_step(step_fn, acc_event) do
    case step_fn.(acc_event) do
      %__MODULE__{dropped?: true} = dropped -> {:halt, dropped}
      %__MODULE__{dropped?: false} = event -> {:cont, event}
    end
  end

  defp new(domain, request) do
    struct!(__MODULE__, domain: domain, request: request)
  end

  defp new(domain, site, request) do
    struct!(__MODULE__, domain: domain, site: site, request: request)
  end

  defp drop(%__MODULE__{} = event, reason, attrs \\ []) do
    fields =
      attrs
      |> Keyword.put(:dropped?, true)
      |> Keyword.put(:drop_reason, reason)

    emit_telemetry_dropped(event, reason)
    struct!(event, fields)
  end

  defp update_event_attrs(%__MODULE__{} = event, %{} = attrs) do
    struct!(event, clickhouse_event_attrs: Map.merge(event.clickhouse_event_attrs, attrs))
  end

  defp update_session_attrs(%__MODULE__{} = event, %{} = attrs) do
    struct!(event, clickhouse_session_attrs: Map.merge(event.clickhouse_session_attrs, attrs))
  end

  defp drop_verification_agent(%__MODULE__{} = event) do
    case event.request.user_agent do
      @verification_user_agent ->
        drop(event, :verification_agent)

      _ ->
        event
    end
  end

  defp drop_datacenter_ip(%__MODULE__{} = event) do
    case event.request.ip_classification do
      "dc_ip" ->
        drop(event, :dc_ip)

      _any ->
        event
    end
  end

  defp drop_shield_rule_ip(%__MODULE__{} = event) do
    if Plausible.Shields.ip_blocked?(event.domain, event.request.remote_ip) do
      drop(event, :site_ip_blocklist)
    else
      event
    end
  end

  defp drop_shield_rule_hostname(%__MODULE__{} = event) do
    if Plausible.Shields.hostname_allowed?(event.domain, event.request.hostname) do
      event
    else
      drop(event, :site_hostname_allowlist)
    end
  end

  defp drop_shield_rule_page(%__MODULE__{} = event) do
    if Plausible.Shields.page_blocked?(event.domain, event.request.pathname) do
      drop(event, :site_page_blocklist)
    else
      event
    end
  end

  defp put_user_agent(%__MODULE__{} = event) do
    case parse_user_agent(event.request) do
      %UAInspector.Result{client: %UAInspector.Result.Client{name: "Headless Chrome"}} ->
        drop(event, :bot)

      %UAInspector.Result.Bot{} ->
        drop(event, :bot)

      %UAInspector.Result{} = user_agent ->
        update_session_attrs(event, %{
          operating_system: os_name(user_agent),
          operating_system_version: os_version(user_agent),
          browser: browser_name(user_agent),
          browser_version: browser_version(user_agent),
          screen_size: screen_size(user_agent)
        })

      _any ->
        event
    end
  end

  defp put_basic_info(%__MODULE__{} = event) do
    update_event_attrs(event, %{
      domain: event.domain,
      site_id: event.site.id,
      timestamp: event.request.timestamp,
      name: event.request.event_name,
      hostname: event.request.hostname,
      pathname: event.request.pathname
    })
  end

  defp put_referrer(%__MODULE__{} = event) do
    ref = parse_referrer(event.request.uri, event.request.referrer)

    update_session_attrs(event, %{
      referrer_source: get_referrer_source(event.request, ref),
      referrer: clean_referrer(ref)
    })
  end

  defp put_utm_tags(%__MODULE__{} = event) do
    query_params = event.request.query_params

    update_session_attrs(event, %{
      utm_medium: query_params["utm_medium"],
      utm_source: query_params["utm_source"],
      utm_campaign: query_params["utm_campaign"],
      utm_content: query_params["utm_content"],
      utm_term: query_params["utm_term"]
    })
  end

  defp put_geolocation(%__MODULE__{} = event) do
    case event.request.ip_classification do
      "anonymous_vpn_ip" ->
        update_session_attrs(event, %{country_code: "A1"})

      _any ->
        result = Plausible.Ingestion.Geolocation.lookup(event.request.remote_ip) || %{}
        update_session_attrs(event, result)
    end
  end

  defp drop_shield_rule_country(
         %__MODULE__{domain: domain, clickhouse_session_attrs: %{country_code: cc}} = event
       )
       when is_binary(domain) and is_binary(cc) do
    if Plausible.Shields.country_blocked?(domain, cc) do
      drop(event, :site_country_blocklist)
    else
      event
    end
  end

  defp drop_shield_rule_country(%__MODULE__{} = event), do: event

  defp put_props(%__MODULE__{request: %{props: %{} = props}} = event) do
    # defensive: ensuring the keys/values are always in the same order
    {keys, values} = Enum.unzip(props)

    update_event_attrs(event, %{
      "meta.key": keys,
      "meta.value": values
    })
  end

  defp put_props(%__MODULE__{} = event), do: event

  defp put_revenue(event) do
    on_ee do
      attrs = Plausible.Ingestion.Event.Revenue.get_revenue_attrs(event)
      update_event_attrs(event, attrs)
    else
      event
    end
  end

  defp put_salts(%__MODULE__{} = event) do
    %{event | salts: Plausible.Session.Salts.fetch()}
  end

  defp put_user_id(%__MODULE__{} = event) do
    update_event_attrs(event, %{
      user_id:
        generate_user_id(
          event.request,
          event.domain,
          event.clickhouse_event_attrs.hostname,
          event.salts.current
        )
    })
  end

  defp validate_clickhouse_event(%__MODULE__{} = event) do
    clickhouse_event =
      event
      |> Map.fetch!(:clickhouse_event_attrs)
      |> ClickhouseEventV2.new()

    case Ecto.Changeset.apply_action(clickhouse_event, nil) do
      {:ok, valid_clickhouse_event} ->
        %{event | clickhouse_event: valid_clickhouse_event}

      {:error, changeset} ->
        drop(event, :invalid, changeset: changeset)
    end
  end

  defp register_session(%__MODULE__{} = event) do
    previous_user_id =
      generate_user_id(
        event.request,
        event.domain,
        event.clickhouse_event.hostname,
        event.salts.previous
      )

    session =
      Plausible.Session.CacheStore.on_event(
        event.clickhouse_event,
        event.clickhouse_session_attrs,
        previous_user_id
      )

    %{
      event
      | clickhouse_event: ClickhouseEventV2.merge_session(event.clickhouse_event, session)
    }
  end

  defp write_to_buffer(%__MODULE__{clickhouse_event: clickhouse_event} = event) do
    {:ok, _} = Plausible.Event.WriteBuffer.insert(clickhouse_event)
    emit_telemetry_buffered(event)
    event
  end

  defp parse_referrer(_uri, _referrer_str = nil), do: nil

  defp parse_referrer(uri, referrer_str) do
    referrer_uri = URI.parse(referrer_str)

    if Request.sanitize_hostname(referrer_uri.host) !== Request.sanitize_hostname(uri.host) &&
         referrer_uri.host !== "localhost" do
      RefInspector.parse(referrer_str)
    end
  end

  defp get_referrer_source(request, ref) do
    tagged_source =
      request.query_params["utm_source"] ||
        request.query_params["source"] ||
        request.query_params["ref"]

    if tagged_source do
      Plausible.Ingestion.Acquisition.find_mapping(tagged_source)
    else
      PlausibleWeb.RefInspector.parse(ref)
    end
  end

  defp clean_referrer(nil), do: nil

  defp clean_referrer(ref) do
    uri = URI.parse(ref.referer)

    if PlausibleWeb.RefInspector.right_uri?(uri) do
      PlausibleWeb.RefInspector.format_referrer(uri)
    end
  end

  defp parse_user_agent(%Request{user_agent: user_agent}) when is_binary(user_agent) do
    Plausible.Cache.Adapter.get(:user_agents, user_agent, fn ->
      UAInspector.parse(user_agent)
    end)
  end

  defp parse_user_agent(request), do: request

  defp browser_name(ua) do
    case ua.client do
      :unknown -> ""
      %UAInspector.Result.Client{name: "Mobile Safari"} -> "Safari"
      %UAInspector.Result.Client{name: "Chrome Mobile"} -> "Chrome"
      %UAInspector.Result.Client{name: "Chrome Mobile iOS"} -> "Chrome"
      %UAInspector.Result.Client{name: "Firefox Mobile"} -> "Firefox"
      %UAInspector.Result.Client{name: "Firefox Mobile iOS"} -> "Firefox"
      %UAInspector.Result.Client{name: "Opera Mobile"} -> "Opera"
      %UAInspector.Result.Client{name: "Opera Mini"} -> "Opera"
      %UAInspector.Result.Client{name: "Opera Mini iOS"} -> "Opera"
      %UAInspector.Result.Client{name: "Yandex Browser Lite"} -> "Yandex Browser"
      %UAInspector.Result.Client{name: "Chrome Webview"} -> "Mobile App"
      %UAInspector.Result.Client{type: "mobile app"} -> "Mobile App"
      client -> client.name
    end
  end

  @mobile_types [
    "smartphone",
    "feature phone",
    "portable media player",
    "phablet",
    "wearable",
    "camera"
  ]
  @tablet_types ["car browser", "tablet"]
  @desktop_types ["tv", "console", "desktop"]
  alias UAInspector.Result.Device

  defp screen_size(ua) do
    case ua.device do
      %Device{type: t} when t in @mobile_types ->
        "Mobile"

      %Device{type: t} when t in @tablet_types ->
        "Tablet"

      %Device{type: t} when t in @desktop_types ->
        "Desktop"

      %Device{type: :unknown} ->
        nil

      %Device{type: type} ->
        Sentry.capture_message("Could not determine device type from UAInspector",
          extra: %{type: type}
        )

        nil

      _ ->
        nil
    end
  end

  defp browser_version(ua) do
    case ua.client do
      :unknown -> ""
      %UAInspector.Result.Client{type: "mobile app"} -> ""
      client -> major_minor(client.version)
    end
  end

  defp os_name(ua) do
    case ua.os do
      :unknown -> ""
      os -> os.name
    end
  end

  defp os_version(ua) do
    case ua.os do
      :unknown -> ""
      os -> major_minor(os.version)
    end
  end

  defp major_minor(version) do
    case version do
      :unknown ->
        ""

      version ->
        version
        |> String.split(".")
        |> Enum.take(2)
        |> Enum.join(".")
    end
  end

  defp generate_user_id(request, domain, hostname, salt) do
    cond do
      is_nil(salt) ->
        nil

      is_nil(domain) ->
        nil

      true ->
        user_agent = request.user_agent || ""
        root_domain = get_root_domain(hostname)

        SipHash.hash!(salt, user_agent <> request.remote_ip <> domain <> root_domain)
    end
  end

  defp get_root_domain(nil), do: "(none)"

  defp get_root_domain(hostname) do
    case :inet.parse_ipv4_address(String.to_charlist(hostname)) do
      {:ok, _} ->
        hostname

      {:error, :einval} ->
        PublicSuffix.registrable_domain(hostname) || hostname
    end
  end

  defp spam_referrer?(%Request{referrer: referrer}) when is_binary(referrer) do
    URI.parse(referrer).host
    |> Request.sanitize_hostname()
    |> ReferrerBlocklist.is_spammer?()
  end

  defp spam_referrer?(_), do: false
end
